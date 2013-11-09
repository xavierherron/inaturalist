#encoding: utf-8
class GuidesController < ApplicationController
  include GuidesHelper
  doorkeeper_for :show, :user, :if => lambda { authenticate_with_oauth? }
  before_filter :authenticate_user!, 
    :except => [:index, :show, :search], 
    :unless => lambda { authenticated_with_oauth? }
  before_filter :load_record, :only => [:show, :edit, :update, :destroy, :import_taxa, :reorder, :add_color_tags, :add_tags_for_rank]
  before_filter :require_owner, :only => [:edit, :update, :destroy, :import_taxa, :reorder, :add_color_tags, :add_tags_for_rank]
  before_filter :load_user_by_login, :only => [:user]

  layout "bootstrap"
  PDF_LAYOUTS = GuidePdfFlowTask::LAYOUTS

  caches_page :show, :if => Proc.new {|c| c.request.format == :ngz || c.request.format == :xml}
  
  # GET /guides
  # GET /guides.json
  def index
    @guides = if logged_in? && params[:by] == "you"
      current_user.guides.limit(100).order("guides.id DESC")
    else
      Guide.page(params[:page]).order("guides.id DESC").published
    end
    @guides = @guides.near_point(params[:latitude], params[:longitude]) if params[:latitude] && params[:longitude]

    unless params[:place_id].blank?
      @place = Place.find(params[:place_id]) rescue nil
      if @place
        @guides = @guides.joins(:place).where("places.id = ? OR (#{Place.send(:sanitize_sql, @place.descendant_conditions)})", @place)
      end
    end

    unless params[:taxon_id].blank?
      @taxon = Taxon.find_by_id(params[:taxon_id])
      if @taxon
        @guides = @guides.joins(:taxon).where("taxa.id = ? OR (#{Taxon.send(:sanitize_sql, @taxon.descendant_conditions)})", @taxon)
      end
    end

    nav_places_for_index
    nav_taxa_for_index

    pagination_headers_for(@observations)
    respond_to do |format|
      format.html
      format.json { render json: @guides }
    end
  end

  private
  def nav_places_for_index
    if @place
      ancestry_counts_scope = Place.joins("INNER JOIN guides ON guides.place_id = places.id").scoped
      ancestry_counts_scope = ancestry_counts_scope.where(@place.descendant_conditions) if @place
      ancestry_counts = ancestry_counts_scope.group("ancestry || '/' || places.id::text").count
      if ancestry_counts.blank?
        @nav_places = []
      else
        ancestries = ancestry_counts.map{|a,c| a.to_s.split('/')}.sort_by(&:size).select{|a| a.size > 0}
        width = ancestries.last.size
        matrix = ancestries.map do |a|
          a + ([nil]*(width-a.size))
        end
        # start at the right col (lowest rank), look for the first occurrence of
        # consensus within a rank
        consensus_node_id, subconsensus_node_ids = nil, nil
        (width - 1).downto(0) do |c|
          column_node_ids = matrix.map{|ancestry| ancestry[c]}
          if column_node_ids.uniq.size == 1 && !column_node_ids.first.blank?
            consensus_node_id = column_node_ids.first
            subconsensus_node_ids = matrix.map{|ancestry| ancestry[c+1]}.uniq
            break
          end
        end
        @nav_places = Place.where("id IN (?)", subconsensus_node_ids)
        @nav_places = @nav_places.sort_by(&:name)
      end
    else
      @nav_places = Place.continents.order(:name)
    end
    @nav_places_counts = {}
    @nav_places.each do |p|
      @nav_places_counts[p.id] = @guides.joins(:place).where("places.id = ? OR (#{Place.send(:sanitize_sql, p.descendant_conditions)})", p).count
    end
    @nav_places_counts.each do |place_id,count|
      @nav_places.reject!{|p| p.id == place_id} if count == 0
    end
  end

  def nav_taxa_for_index
    if @taxon
      ancestry_counts_scope = Taxon.joins("INNER JOIN guides ON guides.taxon_id = taxa.id").scoped
      ancestry_counts_scope = ancestry_counts_scope.where(@taxon.descendant_conditions) if @taxon
      # ancestry_counts = ancestry_counts_scope.group(:ancestry).count
      ancestry_counts = ancestry_counts_scope.group("ancestry || '/' || taxa.id::text").count
      if ancestry_counts.blank?
        @nav_taxa = []
      else
        ancestries = ancestry_counts.map{|a,c| a.to_s.split('/')}.sort_by(&:size).select{|a| a.size > 0 && a[0] == Taxon::LIFE.id.to_s}
        width = ancestries.last.size
        matrix = ancestries.map do |a|
          a + ([nil]*(width-a.size))
        end
        # start at the right col (lowest rank), look for the first occurrence of
        # consensus within a rank
        consensus_taxon_id, subconsensus_taxon_ids = nil, nil
        (width - 1).downto(0) do |c|
          column_taxon_ids = matrix.map{|ancestry| ancestry[c]}
          if column_taxon_ids.uniq.size == 1 && !column_taxon_ids.first.blank?
            consensus_taxon_id = column_taxon_ids.first
            subconsensus_taxon_ids = matrix.map{|ancestry| ancestry[c+1]}.uniq
            break
          end
        end
        @nav_taxa = Taxon.where("id IN (?)", subconsensus_taxon_ids).includes(:taxon_names).sort_by(&:name)
      end
    else
      @nav_taxa = Taxon::ICONIC_TAXA.select{|t| t.rank == Taxon::KINGDOM}
    end
    @nav_taxa_counts = {}
    @nav_taxa.each do |t|
      @nav_taxa_counts[t.id] = @guides.joins(:taxon).where("taxa.id = ? OR (#{Taxon.send(:sanitize_sql, t.descendant_conditions)})", t).count
    end
    @nav_taxa_counts.each do |taxon_id,count|
      @nav_taxa.reject!{|t| t.id == taxon_id} if count == 0
    end
  end
  public

  # GET /guides/1
  # GET /guides/1.json
  def show
    unless @guide.published? || @guide.user_id == current_user.try(:id)
      respond_to do |format|
        format.any(:html, :mobile) { render(:file => "#{Rails.root}/public/404.html", :status => 404, :layout => false) }
        format.any(:xml, :ngz) { render :status => 404, :text => ""}
        format.json { render :json => {:error => "Not found"}, :status => 404 }
      end
      return
    end
    guide_taxa_from_params

    respond_to do |format|
      format.html do
        @guide_taxa = @guide_taxa.page(params[:page]).per_page(100)
        @tag_counts = Tag.joins(:taggings).
          joins("JOIN guide_taxa gt ON gt.id = taggings.taggable_id").
          where("taggings.taggable_type = 'GuideTaxon' AND gt.guide_id = ?", @guide).
          group("tags.name").
          count
        @nav_tags = ActiveSupport::OrderedHash.new
        @tag_counts.each do |tag, count|
          namespace, predicate = nil, "tags"
          nsp, value = tag.split('=')
          if value.blank?
            value = nsp
          else
            namespace, predicate = nsp.to_s.split(':')
            predicate = namespace if predicate.blank?
          end
          @nav_tags[predicate] ||= []
          @nav_tags[predicate] << [tag, value, count]
        end
        
        ancestry_counts_scope = Taxon.joins(:guide_taxa).where("guide_taxa.guide_id = ?", @guide).scoped
        ancestry_counts_scope = ancestry_counts_scope.where(@taxon.descendant_conditions) if @taxon
        ancestry_counts = ancestry_counts_scope.group(:ancestry).count
        if ancestry_counts.blank?
          @nav_taxa = []
        else
          ancestries = ancestry_counts.map{|a,c| a.to_s.split('/')}.sort_by(&:size).select{|a| a.size > 0 && a[0] == Taxon::LIFE.id.to_s}
          width = ancestries.last.size
          matrix = ancestries.map do |a|
            a + ([nil]*(width-a.size))
          end
          # start at the right col (lowest rank), look for the first occurrence of
          # consensus within a rank
          consensus_taxon_id, subconsensus_taxon_ids = nil, nil
          (width - 1).downto(0) do |c|
            column_taxon_ids = matrix.map{|ancestry| ancestry[c]}
            if column_taxon_ids.uniq.size == 1 && !column_taxon_ids.first.blank?
              consensus_taxon_id = column_taxon_ids.first
              subconsensus_taxon_ids = matrix.map{|ancestry| ancestry[c+1]}.uniq
              break
            end
          end
          @nav_taxa = Taxon.where("id IN (?)", subconsensus_taxon_ids).includes(:taxon_names).sort_by(&:name)
          @nav_taxa_counts = {}
          @nav_taxa.each do |t|
            @nav_taxa_counts[t.id] = @guide.guide_taxa.joins(:taxon).where(t.descendant_conditions).count
          end
        end
      end

      format.json { render json: @guide.as_json(:root => true) }

      format.pdf do
        @layout = params[:layout] if GuidePdfFlowTask::LAYOUTS.include?(params[:layout])
        @layout ||= GuidePdfFlowTask::GRID
        @template = "guides/show_#{@layout}.pdf.haml"
        if params[:print].present?
          render :pdf => "#{@guide.title.parameterize}.#{@layout}", 
            :layout => "bootstrap.pdf",
            :template => @template,
            :orientation => @layout == "journal" ? 'Landscape' : nil,
            :show_as_html => params[:pdf].blank?,
            :margin => {
              :left => 0,
              :right => 0
            }
        elsif params[:flow_task_id] && flow_task = FlowTask.find_by_id(params[:flow_task_id])
          redirect_to flow_task.pdf_url
        else
          matching_flow_task = GuidePdfFlowTask.
            select("DISTINCT ON (flow_tasks.id) flow_tasks.*").
            joins("INNER JOIN flow_task_resources inputs ON inputs.flow_task_id = flow_tasks.id").
            joins("INNER JOIN flow_task_resources outputs ON inputs.flow_task_id = flow_tasks.id").
            where("inputs.type = 'FlowTaskInput'").
            where("outputs.type = 'FlowTaskOutput'").
            where("inputs.resource_type = 'Guide' AND inputs.resource_id = ?", @guide).
            where("outputs.file_file_name IS NOT NULL").
            order("flow_tasks.id DESC").
            detect{|ft| ft.options['layout'] == @layout}
          if matching_flow_task && 
              matching_flow_task.created_at > @guide.updated_at && 
              (matching_flow_task.options['query'].blank? || matching_flow_task.options['query'] == 'all') &&
              !@guide.guide_taxa.where("updated_at > ?", matching_flow_task.created_at).exists? &&
              !GuidePhoto.joins(:guide_taxon).where("guide_taxa.guide_id = ?", @guide).where("guide_photos.updated_at > ?", matching_flow_task.created_at).exists? &&
              !GuideSection.joins(:guide_taxon).where("guide_taxa.guide_id = ?", @guide).where("guide_sections.updated_at > ?", matching_flow_task.created_at).exists? &&
              !GuideRange.joins(:guide_taxon).where("guide_taxa.guide_id = ?", @guide).where("guide_ranges.updated_at > ?", matching_flow_task.created_at).exists? &&
              matching_flow_task.pdf_url
            redirect_to matching_flow_task.pdf_url
          else
            render :status => :not_found, :text => "", :layout => false
          end
        end
      end
      format.xml
      format.ngz do
        path = "public/guides/#{@guide.to_param}.ngz"
        job_id = Rails.cache.read(@guide.generate_ngz_cache_key)
        job = Delayed::Job.find_by_id(job_id)
        if job
          # Still working
        else
          # no job id, no job, let's get this party started
          Rails.cache.delete(@guide.generate_ngz_cache_key)
          job = @guide.delay.generate_ngz(:path => path)
          Rails.cache.write(@guide.generate_ngz_cache_key, job.id, :expires_in => 1.hour)
        end
        prevent_caching
        # Would prefer to use accepted, but don't want to deliver an invlid zip file
        render :status => :no_content, :layout => false, :text => ""
      end
    end
  end

  # GET /guides/new
  # GET /guides/new.json
  def new
    @guide = Guide.new
    unless params[:source_url].blank?
      @guide.source_url = params[:source_url]
      @guide.set_defaults_from_source_url(:skip_icon => true)
    end
    respond_to do |format|
      format.html # new.html.erb
      format.json { render json: @guide.as_json(:root => true) }
    end
  end

  # GET /guides/1/edit
  def edit
    @nav_options = %w(iconic tag)
    @guide_taxa = @guide.guide_taxa.includes(:taxon, {:guide_photos => :photo}, :tags).
      order("guide_taxa.position")
    @recent_tags = @guide.recent_tags
  end

  # POST /guides
  # POST /guides.json
  def create
    @guide = Guide.new(params[:guide])
    @guide.user = current_user
    @guide.published_at = Time.now if params[:publish]

    respond_to do |format|
      if @guide.save
        create_default_guide_taxa
        format.html { redirect_to edit_guide_path(@guide), notice: 'Guide was successfully created.' }
        format.json { render json: @guide.as_json(:root => true), status: :created, location: @guide }
      else
        format.html { render action: "new" }
        format.json { render json: @guide.errors, status: :unprocessable_entity }
      end
    end
  end

  # PUT /guides/1
  # PUT /guides/1.json
  def update
    @guide.icon = nil if params[:icon_delete]
    if params[:publish]
      @guide.published_at = Time.now
    elsif params[:unpublish]
      @guide.published_at = nil
    end
    create_default_guide_taxa
    respond_to do |format|
      if @guide.update_attributes(params[:guide])
        format.html { redirect_to @guide, notice: "Guide was successfully #{params[:publish] ? 'published' : 'updated'}." }
        format.json { head :no_content }
      else
        format.html { render action: "edit" }
        format.json { render json: @guide.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /guides/1
  # DELETE /guides/1.json
  def destroy
    @guide.destroy

    respond_to do |format|
      format.html { redirect_to guides_url, notice: 'Guide deleted.' }
      format.json { head :no_content }
    end
  end

  def import_taxa
    @guide_taxa = @guide.import_taxa(params) || []
    respond_to do |format|
      format.json do
        if partial = params[:partial]
          @guide_taxa.each_with_index do |gt, i|
            next if gt.new_record?
            @guide_taxa[i].html = view_context.render_in_format(:html, partial, :guide_taxon => gt)
          end
        end
        render :json => {:guide_taxa => @guide_taxa.as_json(:root => false, :methods => [:errors, :html, :valid?])}
      end
    end
  end

  def search
    @guides = Guide.published.dbsearch(params[:q]).page(params[:page])
    pagination_headers_for @guides
    respond_to do |format|
      format.html
      format.json do
        render :json => @guides
      end
    end
  end

  def reorder
    @guide.reorder_by_taxonomy
    respond_to do |format|
      format.html { redirect_to edit_guide_path(@guide) }
      format.json { render :status => 204 }
    end
  end

  def user
    @guides = current_user.guides.page(params[:page]).per_page(500)
    pagination_headers_for(@observations)
    respond_to do |format|
      format.html
      format.json { render :json => @guides }
    end
  end

  def add_color_tags
    @guide_taxa = @guide.guide_taxa.includes(:taxon => [:colors]).where("colors.id IS NOT NULL").scoped
    @guide_taxa = @guide_taxa.where("guide_taxa.id IN (?)", params[:guide_taxon_ids]) unless params[:guide_taxon_ids].blank?
    @guide_taxa.each do |gt|
      gt.add_color_tags
    end
    respond_to do |format|
      format.json { render :json => @guide_taxa.as_json(:methods => [:tag_list])}
    end
  end

  def add_tags_for_rank
    @guide_taxa = @guide.guide_taxa.includes(:taxon => [:taxon_names]).scoped
    @guide_taxa = @guide_taxa.where("guide_taxa.id IN (?)", params[:guide_taxon_ids]) unless params[:guide_taxon_ids].blank?
    @guide_taxa.each do |gt|
      gt.add_rank_tag(params[:rank], :lexicon => params[:lexicon])
    end
    respond_to do |format|
      format.json { render :json => @guide_taxa.as_json(:methods => [:tag_list])}
    end
  end

  private

  def create_default_guide_taxa
    @guide.import_taxa(params)
  end
end
