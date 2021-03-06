module Lipsiadmin
  # Attachment allows file attachments that are stored in the filesystem. All graphical
  # transformations are done using the Graphics/ImageMagick command line utilities and
  # are stored in Tempfiles until the record is saved. Attachment does not require a
  # separate model for storing the attachment's information, instead adding a few simple
  # columns to your table.
  #
  # Author:: Jon Yurek
  # Copyright:: Copyright (c) 2008 thoughtbot, inc.
  # License:: MIT License (http://www.opensource.org/licenses/mit-license.php)
  #
  # Attachment defines an attachment as any file, though it makes special considerations
  # for image files. You can declare that a model has an attached file with the
  # +has_one_attachment+ method:
  # 
  # From your console:
  #   script/generate attachment
  # 
  # Then in any model you can do:
  #
  #   class User < ActiveRecord::Base
  #     has_many_attachments                  :attachments, :dependent => :destroy
  #     has_one_attachment                    :image
  #     attachment_styles_for                 :attachments, :normal, "128x128!"
  #     validates_attachment_presence_for     :attachments
  #     validates_attachment_size_for         :attachments, :greater_than => 10.megabytes
  #     validates_attachment_content_type_for :attachments, "image/png"
  #   end
  #
  # See the <tt>Lipsiadmin::DataBase::Attachment::ClassMethods</tt> documentation for more details.
  module Attachment
    
    class << self
      # Provides configurability to Attachment. There are a number of options available, such as:
      # * whiny_thumbnails: Will raise an error if Attachment cannot process thumbnails of 
      #   an uploaded image. Defaults to false.
      # * log: Logs progress to the Rails log. Uses ActiveRecord's logger, so honors
      #   log levels, etc. Defaults to true.
      # * command_path: Defines the path at which to find the command line
      #   programs if they are not visible to Rails the system's search path. Defaults to 
      #   nil, which uses the first executable found in the user's search path.
      # * image_magick_path: Deprecated alias of command_path.
      def options
        @options ||= {
          :whiny_thumbnails  => false,
          :command_path      => nil,
          :log               => true,
          :swallow_stderr    => true
        }
      end

      def processor(name) #:nodoc:
        name = name.to_s.camelize
        processor = Lipsiadmin::Attachment.const_get(name)
        unless processor.ancestors.include?(Lipsiadmin::Attachment::Processor)
          raise AttachmentError.new("Processor #{name} was not found") 
        end
        processor
      end
      
      def interpolates(key, &block) #:nodoc:
        Lipsiadmin::Attachment.interpolations[key] = block
      end
      
      # The run method takes a command to execute and a string of parameters
      # that get passed to it. The command is prefixed with the :command_path
      # option from Attachment.options. If you have many commands to run and
      # they are in different paths, the suggested course of action is to
      # symlink them so they are all in the same directory.
      #
      # If the command returns with a result code that is not one of the
      # expected_outcodes, a AttachmentCommandLineError will be raised. Generally
      # a code of 0 is expected, but a list of codes may be passed if necessary.
      def run(cmd, params = "", expected_outcodes = 0)
        command = %Q<#{%Q[#{path_for_command(cmd)} #{params}].gsub(/\s+/, " ")}>
        command = "#{command} 2>#{bit_bucket}" if Attachment.options[:swallow_stderr]
        output = `#{command}`
        unless [expected_outcodes].flatten.include?($?.exitstatus)
          raise AttachmentCommandLineError, "Error while running #{cmd}"
        end
        output
      end
      
      def path_for_command(command)#:nodoc:
        path = [options[:command_path] || options[:image_magick_path], command].compact
        File.join(*path)
      end

      def bit_bucket #:nodoc:
        File.exists?("/dev/null") ? "/dev/null" : "NUL"
      end
    end
    
    class AttachmentError < StandardError #:nodoc:
    end

    class AttachmentCommandLineError < StandardError #:nodoc:
    end

    class NotIdentifiedByImageMagickError < AttachmentError #:nodoc:
    end
    
    # The Attachment class manages the files for a given attachment. It saves
    # when the model saves, deletes when the model is destroyed, and processes
    # the file upon assignment.
    class Attach

      def self.default_options
        @default_options ||= {
          :url           => "/uploads/:id_:style_:basename.:extension",
          :path          => ":rails_root/public/uploads/:id_:style_:basename.:extension",
          :styles        => {},
          :default_url   => "/images/backend/no-image.png",
          :default_style => :original,
          :validations   => {},
          :storage       => :filesystem
        }
      end

      attr_reader :name, :instance, :styles, :default_style, :convert_options, :queued_for_write

      # Creates an Attachment object. +name+ is the name of the attachment,
      # +instance+ is the ActiveRecord object instance it's attached to, and
      # +options+ is the same as the hash passed to +has_attached_file+.
      def initialize(name, instance, options = {})
        @name              = name
        @instance          = instance

        options = self.class.default_options.merge(options)

        @url               = options[:url]
        @path              = options[:path]
        @styles            = options[:styles]
        @default_url       = options[:default_url]
        @validations       = options[:validations]
        @default_style     = options[:default_style]
        @storage           = options[:storage]
        @whiny             = options[:whiny_thumbnails]
        @convert_options   = options[:convert_options] || {}
        @background        = options[:background].nil? ? instance.respond_to?(:spawn) : options[:background]
        @processors        = options[:processors] || [:thumbnail]
        @options           = options
        @queued_for_delete = []
        @queued_for_write  = {}
        @errors            = {}
        @validation_errors = nil
        @dirty             = false

        normalize_style_definition
        initialize_storage
                
        log("Attachment on #{instance.class} initialized.")
      end

      # What gets called when you call instance.attachment = File. It clears
      # errors, assigns attributes, processes the file, and runs validations. It
      # also queues up the previous file for deletion, to be flushed away on
      # #save of its host.  In addition to form uploads, you can also assign
      # another Attachment attachment: 
      #   new_user.avatar = old_user.avatar
      # If the file that is assigned is not valid, the processing (i.e.
      # thumbnailing, etc) will NOT be run.
      def assign(uploaded_file)
        %w(file_name).each do |field|
          unless @instance.class.column_names.include?("#{name}_#{field}")
            raise AttachmentError.new("#{@instance.class} model does not have required column '#{name}_#{field}'")
          end
        end

        if uploaded_file.is_a?(Lipsiadmin::Attachment::Attach)
          uploaded_file = uploaded_file.to_file(:original)
          close_uploaded_file = uploaded_file.respond_to?(:close)
        end

        return nil unless valid_assignment?(uploaded_file)
        log("Assigning #{uploaded_file.inspect} to #{name}")

        uploaded_file.binmode if uploaded_file.respond_to? :binmode
        queue_existing_for_delete
        @errors            = {}
        @validation_errors = nil

        return nil if uploaded_file.nil?

        log("Writing attributes for #{name}")
        @queued_for_write[:original]   = uploaded_file.to_tempfile
        instance_write(:file_name,       uploaded_file.original_filename.strip.gsub(/[^\w\d\.\-]+/, '_'))
        instance_write(:content_type,    uploaded_file.content_type.to_s.strip)
        instance_write(:file_size,       uploaded_file.size.to_i)
        instance_write(:updated_at,      Time.now)

        @dirty = true

        solidify_style_definitions
        post_process if valid?
        
        # Reset the file size if the original file was reprocessed.
        instance_write(:file_size, @queued_for_write[:original].size.to_i)
      ensure
        uploaded_file.close if close_uploaded_file
        validate
      end

      # Returns the public URL of the attachment, with a given style. Note that
      # this does not necessarily need to point to a file that your web server
      # can access and can point to an action in your app, if you need fine
      # grained security.  This is not recommended if you don't need the
      # security, however, for performance reasons.  set
      # include_updated_timestamp to false if you want to stop the attachment
      # update time appended to the url
      def url(style = default_style, include_updated_timestamp = true)
        if original_filename.nil?
          url = interpolate(@default_url, style)
        elsif File.exist?(path(style))
          url = interpolate(@url, style)
        else
          url = interpolate(@url, :original)
        end
        include_updated_timestamp && updated_at ? [url, updated_at].compact.join(url.include?("?") ? "&" : "?") : url
      end

      # Returns the path of the attachment as defined by the :path option. If the
      # file is stored in the filesystem the path refers to the path of the file
      # on disk. If the file is stored in S3, the path is the "key" part of the
      # URL, and the :bucket option refers to the S3 bucket.
      def path(style = nil) #:nodoc:
        original_filename.nil? ? nil : interpolate(@path, style)
      end

      # Alias to +url+
      def to_s(style = nil)
        url(style)
      end

      # Returns true if there are no errors on this attachment.
      def valid?
        validate
        errors.empty?
      end

      # Returns an array containing the errors on this attachment.
      def errors
        @errors
      end

      # Returns true if there are changes that need to be saved.
      def dirty?
        @dirty
      end

      # Saves the file, if there are no errors. If there are, it flushes them to
      # the instance's errors and returns false, cancelling the save.
      def save
        if valid?
          log("Saving files for #{name}")
          flush_deletes
          flush_writes
          @dirty = false
          true
        else
          log("Errors on #{name}. Not saving.")
          flush_errors
          false
        end
      end

      # Returns the name of the file as originally assigned, and lives in the
      # <attachment>_file_name attribute of the model.
      def original_filename
        instance_read(:file_name)
      end

      # Returns the size of the file as originally assigned, and lives in the
      # <attachment>_file_size attribute of the model.
      def size
        instance_read(:file_size) || (@queued_for_write[:original] && @queued_for_write[:original].size)
      end

      # Returns the content_type of the file as originally assigned, and lives
      # in the <attachment>_content_type attribute of the model.
      def content_type
        instance_read(:content_type)
      end

      # Returns the last modified time of the file as originally assigned, and 
      # lives in the <attachment>_updated_at attribute of the model.
      def updated_at
        time = instance_read(:updated_at)
        time && time.to_i
      end

      # A hash of procs that are run during the interpolation of a path or url.
      # A variable of the format :name will be replaced with the return value of
      # the proc named ":name". Each lambda takes the attachment and the current
      # style as arguments. This hash can be added to with your own proc if
      # necessary.
      def self.interpolations
        @interpolations ||= {
          :rails_root   => lambda{|attachment,style| RAILS_ROOT },
          :rails_env    => lambda{|attachment,style| RAILS_ENV },
          :class        => lambda do |attachment,style|
                             attachment.instance.class.name.underscore.pluralize
                           end,
          :basename     => lambda do |attachment,style|
                             attachment.original_filename.gsub(/#{File.extname(attachment.original_filename)}$/, "")
                           end,
          :extension    => lambda do |attachment,style| 
                             ((style = attachment.styles[style]) && style[:format]) ||
                             File.extname(attachment.original_filename).gsub(/^\.+/, "")
                           end,
          :id           => lambda{|attachment,style| attachment.instance.id },
          :id_partition => lambda do |attachment, style|
                             ("%09d" % attachment.instance.id).scan(/\d{3}/).join("/")
                           end,
          :attachment   => lambda{|attachment,style| attachment.name.to_s.downcase.pluralize },
          :style        => lambda{|attachment,style| style || attachment.default_style },
        }
      end

      # This method really shouldn't be called that often. It's expected use is
      # in the attachment:refresh rake task and that's it. It will regenerate all
      # thumbnails forcefully, by reobtaining the original file and going through
      # the post-process again.
      def reprocess!
        new_original = Tempfile.new("attachment-reprocess")
        new_original.binmode
        if old_original = to_file(:original)
          new_original.write( old_original.read )
          new_original.rewind

          @queued_for_write = { :original => new_original }
          post_process

          old_original.close if old_original.respond_to?(:close)

          save
        else
          true
        end
      end

      # Returns true if a file has been assigned.
      def exist?
        !original_filename.blank?
      end

      # Writes the attachment-specific attribute on the instance. For example,
      # instance_write(:file_name, "me.jpg") will write "me.jpg" to the instance's
      # "avatar_file_name" field (assuming the attachment is called avatar).
      def instance_write(attr, value)
        setter = :"#{name}_#{attr}="
        responds = instance.respond_to?(setter)
        instance.send(setter, value) if responds || attr.to_s == "file_name"
      end

      # Reads the attachment-specific attribute on the instance. See instance_write
      # for more details.
      def instance_read(attr)
        getter = :"#{name}_#{attr}"
        responds = instance.respond_to?(getter)
        instance.send(getter) if responds || attr.to_s == "file_name"
      end

      def logger #:nodoc:
        instance.logger
      end

      def log message #:nodoc:
        logger.info("[Attachment] #{message}") if logging?
      end

      def logging? #:nodoc:
        Lipsiadmin::Attachment.options[:log]
      end

      def valid_assignment? file #:nodoc:
        file.nil? || (file.respond_to?(:original_filename) && file.respond_to?(:content_type))
      end

      def validate #:nodoc:
        unless @validation_errors
          @validation_errors = @validations.inject({}) do |errors, validation|
            name, block = validation
            errors[name] = block.call(self, instance) if block
            errors
          end
          @validation_errors.reject!{|k,v| v == nil }
          @errors.merge!(@validation_errors)
        end
        @validation_errors
      end

      def normalize_style_definition #:nodoc:
        @styles.each do |name, args|
          unless args.is_a? Hash
            dimensions, format = [args, nil].flatten[0..1]
            format             = nil if format.blank?
            @styles[name]      = {
              :processors      => @processors,
              :geometry        => dimensions,
              :format          => format,
              :whiny           => @whiny,
              :convert_options => extra_options_for(name)
            }
          else
            @styles[name] = {
              :processors => @processors,
              :whiny => @whiny,
              :convert_options => extra_options_for(name)
            }.merge(@styles[name])
          end
        end
      end

      def solidify_style_definitions #:nodoc:
        @styles.each do |name, args|
          if @styles[name][:geometry].respond_to?(:call)
            @styles[name][:geometry] = @styles[name][:geometry].call(instance) 
          end
        end
      end

      def initialize_storage #:nodoc:
        @storage_module = Attachment::Storage.const_get(@storage.to_s.capitalize)
        self.extend(@storage_module)
      end

      def extra_options_for(style) #:nodoc:
        all_options   = convert_options[:all]
        all_options   = all_options.call(instance)   if all_options.respond_to?(:call)
        style_options = convert_options[style]
        style_options = style_options.call(instance) if style_options.respond_to?(:call)

        [ style_options, all_options ].compact.join(" ")
      end

      def post_process #:nodoc:
        return if @queued_for_write[:original].nil?
        background do
          return if fire_events(:before)
          post_process_styles
          return if fire_events(:after)
        end
      end

      def fire_events(which) #:nodoc:
        return true if callback(:"#{which}_post_process") == false
        return true if callback(:"#{which}_#{name}_post_process") == false
      end

      def post_process_styles #:nodoc:
        log("Post-processing #{name}")
        @styles.each do |name, args|
          begin
            raise RuntimeError.new("Style #{name} has no processors defined.") if args[:processors].blank?
            @queued_for_write[name] = args[:processors].inject(@queued_for_write[:original]) do |file, processor|
              log("Processing #{name} #{file} in the #{processor} processor.")
              Lipsiadmin::Attachment.processor(processor).make(file, args)
            end
          rescue AttachmentError => e
            log("An error was received while processing: #{e.inspect}")
            (@errors[:processing] ||= []) << e.message if @whiny
          end
        end
      end

      # When processing, if the spawn plugin is installed, processing can be done in
      # a background fork or thread if desired.
      def background(&blk)
        # if instance.respond_to?(:spawn) && @background
        #   instance.spawn(&blk)
        # else
          blk.call
        # end
      end

      def callback(which)#:nodoc:
        instance.run_callbacks(which, @queued_for_write){|result, obj| result == false }
      end

      def interpolate(pattern, style = default_style) #:nodoc:
        interpolations = self.class.interpolations.sort{|a,b| a.first.to_s <=> b.first.to_s }
        interpolations.reverse.inject( pattern.dup ) do |result, interpolation|
          tag, blk = interpolation
          match    = blk.call(self, style)
          # If we use tag original we dont want to add :original to filename or url
          tag == :style && match == :original ? result.gsub(/:style_/, "") : result.gsub(/:#{tag}/, match.to_s)
        end
      end

      def queue_existing_for_delete #:nodoc:
        return unless exist?
        log("Queueing the existing files for #{name} for deletion.")
        @queued_for_delete += [:original, *@styles.keys].uniq.map do |style|
          path(style) if exists?(style)
        end.compact
        instance_write(:file_name, nil)
        instance_write(:content_type, nil)
        instance_write(:file_size, nil)
        instance_write(:updated_at, nil)
      end

      def flush_errors #:nodoc:
        @errors.each do |error, message|
          instance.errors.add(name, message) if message
        end
      end

    end
  end
end