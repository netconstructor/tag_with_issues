module TagWithIssues
  module Patches
    module IssuesControllerPatch
      def self.included(base)
        base.send(:include, InstanceMethods)

        base.class_eval do
          unloadable
          # add the tag action to the before_filter methods that trigger find_issues
          # otherwise the @issues variable is not generated from the ids in params.
          # In particular @project will not be set, causing authorize to fail
          base.filter_chain.detect{|filter| filter.method == :find_issues}.options[:only] << "tag" << "create_tag"
          
          before_filter :check_unique_project, :only => [:tag, :create_tag]
          before_filter :find_repository, :only => [:tag, :create_tag]
          before_filter :find_tag_name, :only => [:create_tag]
          before_filter :find_commit, :only => [:create_tag]
        end
      end

      module InstanceMethods
        def tag
          @issues.sort!
          @tag_name_major_version = Setting.plugin_tag_with_issues['major_version']
          @can_edit_major_version = @tag_name_major_version.empty?
          @tag_name_minor_version, @tag_name_internal_version_extra, @tag_name_custom = "", "", ""
          @repository.fetch_changesets if Setting.autofetch_changesets?
          @has_branches = (!@repository.branches.nil? && @repository.branches.length > 0)
          branches = @has_branches ? @repository.branches : [@repository.default_branch]
          @changesets_by_branch = branches.inject({}) { |h,b| h[b] = @repository.latest_changesets("", b); h }

          @tags = @repository.tags.collect do |tag|
            changeset = @repository.latest_changesets("", tag).first
            tag_info = {:name => tag, :id => "?", :commit_message => "<no commit message>"}
            unless changeset.nil?
              tag_info[:id] = changeset.format_identifier
              tag_info[:commit_message] = changeset.comments
              tag_info[:committed_on] = changeset.committed_on
            end
            tag_info
          end
          @tags = @tags.sort_by { |t| t[:committed_on]}.reverse

          unless @tags.empty?
            latest_tag_name = @tags[0][:name]
            if latest_tag_name =~ /\A([^\.]*)\.([^-]*)(-(.*))?\Z/
              @tag_name_minor_version, @tag_name_internal_version_extra = $2, $4
              if @can_edit_major_version
                @tag_name_major_version = $1
              end
            else
              @tag_name_custom = latest_tag_name
            end
          end
        end
        
        def create_tag
          tag_command = Setting.plugin_tag_with_issues['git_tag_command']
          if tag_command.nil? or tag_command.empty?
            render_error "Please configure the tag command in the plugin's config first"
            return false
          end

          tag_command = tag_command.gsub(/<commit_id>/, Redmine::Scm::Adapters::AbstractAdapter::shell_quote(@commit_id))
          tag_command = tag_command.gsub(/<tag_name>/, Redmine::Scm::Adapters::AbstractAdapter::shell_quote(@tag_name))
          tag_command = tag_command.gsub(/<repository_path>/, @repository.url)
          logger.debug "Executing git tag command '#{tag_command}'"
          success = system(tag_command)
          logger.debug "Return value '#{$?}'"

          if success
            flash[:notice] = l(:notice_successfully_created_tag)
          else
            flash[:error] = l(:error_creating_tag) + " (Tag: '#{@tag_name}' commit: '#{@commit.identifier}' Repo:'#{@repository.url}')"
          end
          redirect_to :controller => 'projects', :action => 'show', :id => @project.id
        end
        
        private

        def check_unique_project
          unless @project
            render_error 'Tagging a commit with issues from other projects is not supported'
            return false
          end
        end
        
        def find_repository
          @repository = @project.repository
          (render_404; return false) unless @repository
        rescue ActiveRecord::RecordNotFound
          render_404
        end

        def find_tag_name
          @tag_name = params[:tag_name_custom]
          return true unless @tag_name.empty?

          if params[:tag_name_major_version].empty? or params[:tag_name_minor_version].empty?
            render_error(:message => l(:error_tag_name_insufficient),
                          :status => 500)
            return false
          end

          @tag_name = "#{params[:tag_name_major_version]}-#{params[:tag_name_minor_version]}"
          unless params[:tag_name_internal_version_extra].empty?
            @tag_name += "-#{params[:tag_name_internal_version_extra]}"
          end

          if @repository.tags.include? @tag_name
            render_error(:message => l(:error_tag_name_already_in_use),
                         :status => 500)
            return false
          end
        end

        def find_commit
          @commit_id = params[:commit_id]
          raise ActiveRecord::RecordNotFound if @commit_id.empty?
          @commit = @repository.find_changeset_by_name(@commit_id)
        rescue ActiveRecord::RecordNotFound
          render_404
        end

        def in_tmpdir
          dirname = "#{Time.now.to_i}#{rand(1000)}"
          while File.exists? dirname
            dirname += rand(1000)
          end
          tmpdir = File.expand_path dirname
          FileUtils.mkdir_p(tmpdir)
          yield(tmpdir)
        ensure
          FileUtils.rm_rf(tmpdir) if File.exists?(tmpdir)
        end
      end
    end
  end    
end

IssuesController.send(:include, TagWithIssues::Patches::IssuesControllerPatch)