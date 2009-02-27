class Backend::<%= controller_class_name %>Controller < BackendController

  def index
    params[:limit] ||= 50
    
    @column_store = column_store_for <%= model_name %> do |cm|
      <%- model_instance.class.content_columns.collect do |column| -%>
      cm.add :<%= column.name.downcase %>,  "<%= model_instance.class.human_attribute_name(column.name) %>", :sortable => true<% if column.type == :date %>, :renderer => :date <% elsif column.type == :datetime %>, :renderer => :datetime <% end %>
      <%- end -%>
    end
    
    respond_to do |format|
      format.js 
      format.json do
        render :json => @column_store.store_data(params)
      end
    end
  end

  <% for action in unscaffolded_actions -%>
    def <%= action %><%= suffix %>
    end

  <% end -%>

  def new<%= suffix %>
    @<%= singular_name %> = <%= model_name %>.new
  end

  def create<%= suffix %>
    @<%= singular_name %> = <%= model_name %>.new(params[:<%= singular_name %>])
    if @<%= singular_name %>.save
      redirect_parent_to(:action => "edit", :id => @<%= singular_name %>)
    else
      render_to_parent(:action => "new")
    end
  end

  def edit<%= suffix %>
    @<%= singular_name %> = <%= model_name %>.find(params[:id])
  end

  def update
    @<%= singular_name %> = <%= model_name %>.find(params[:id])    
    if @<%= singular_name %>.update_attributes(params[:<%= singular_name %>])
      redirect_parent_to(:action => "edit", :id => @<%= singular_name %>)
    else
      render_to_parent(:action => "edit")
    end 
  end
  
  # Add in your model before_destroy and if the callback returns false, 
  # all the later callbacks and the associated action are cancelled.
  def destroy<%= suffix %>
    if <%= model_name %>.find(params[:id]).destroy
      render :json => { :success => true } 
    else
      render :json => { :success => false, :msg => I18n.t("backend.general.cantDelete") }
    end
  end
end