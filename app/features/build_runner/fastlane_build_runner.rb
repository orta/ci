require_relative "./fastlane_build_runner_helpers/fastlane_ci_output"
require_relative "./fastlane_build_runner_helpers/fastlane_log"
require_relative "./fastlane_build_runner_helpers/fastlane_output_to_html"
require_relative "./build_runner"
require_relative "../../shared/fastfile_finder"

require "tmpdir"
require "bundler"

module FastlaneCI
  # Represents the build runner responsible for loading and running
  # fastlane Fastfile configurations
  # - Loading up _fastlane_ and running a lane with it, checking the return status
  # - Take the artifacts from fastlane, and store them using the artifact related code of fastlane.ci
  #
  # TODO: run method *should* return an array of artifacts
  #
  class FastlaneBuildRunner < BuildRunner
    include FastlaneCI::Logging

    # Parameters for running fastlane
    attr_reader :platform
    attr_reader :lane
    attr_reader :parameters

    # Set additional values specific to the fastlane build runner
    # TODO: the parameters are not used/implemented yet, see https://github.com/fastlane/ci/issues/783
    def setup(parameters: nil)
      # Setting the variables directly (only having `attr_reader`) as they're immutable
      # Once you define a FastlaneBuildRunner, you shouldn't be able to modify them
      @platform = project.platform
      @lane = project.lane
      @parameters = parameters

      # Append additional metadata to the build for historic information
      current_build.lane = lane
      current_build.platform = platform
      current_build.parameters = self.parameters

      # The call below could be optimized, as it will also set the status
      # on the GitHub remote. We want to store the lane, platform and parameters
      # that's why we call it here in the `setup` method again, as well as in
      # `BuildRunner#prepare_build_object`
      save_build_status!
    end

    # completion_block is called with an array of artifacts
    def run(new_line_block:, completion_block:)
      artifacts_paths = [] # first thing we do, as we access it in the `ensure` block of this method
      require "fastlane"

      ci_output = FastlaneCI::FastlaneCIOutput.new(
        each_line_block: proc do |raw_row|
          new_line_block.call(convert_raw_row_to_object(raw_row))
        end
      )

      temporary_output_directory = Dir.mktmpdir
      verbose_log = FastlaneCI::FastlaneLog.new(
        file_path: File.join(temporary_output_directory, "fastlane.verbose.log"),
        severity: Logger::DEBUG
      )
      info_log = FastlaneCI::FastlaneLog.new(
        file_path: File.join(temporary_output_directory, "fastlane.log")
      )

      ci_output.add_output_listener!(verbose_log)
      ci_output.add_output_listener!(info_log)

      FastlaneCore::UI.ui_object = ci_output

      # this only takes a few ms the first time being called
      Fastlane.load_actions

      fast_file_path = FastlaneCI::FastfileFinder.find_fastfile_in_repo(repo: repo)

      if fast_file_path.nil? || !File.exist?(fast_file_path)
        # rubocop:disable Metrics/LineLength
        logger.info("unable to start fastlane run lane: #{lane} platform: #{platform}, params: #{parameters}, no Fastfile for commit")
        current_build.status = :missing_fastfile
        current_build.description = "We're unable to start fastlane run lane: #{lane} platform: #{platform}, params: #{parameters}, because no Fastfile existed at the time the commit was made"
        # rubocop:enable Metrics/LineLength
        return
      end

      FastlaneCore::Globals.verbose = true

      begin
        # TODO: I think we need to clear out the singleton values, such as lane context, and all that jazz
        # Execute the Fastfile here
        # rubocop:disable Metrics/LineLength
        logger.info("starting fastlane run lane: #{lane} platform: #{platform}, params: #{parameters} from #{fast_file_path}")
        # rubocop:enable Metrics/LineLength

        # TODO: the fast_file.runner should probably handle this
        logger.debug("Switching to #{repo.local_folder} to run `fastlane`")

        # Change over to the repo, inside the `fastlane` folder
        # This is critical to do
        # As only going into the checked out repo folder will cause the
        # fastlane code base to look for the Fastfile again, and with it
        # its configuration files, and with it, cd .. somewhere in the stack
        # causing the rest to not work
        # Using the code below, we ensure we're in the `./fastlane` or `./.fastlane`
        # folder, and all the following code works
        # This is needed to load other configuration files, and also find Xcode projects

        # This step is needed in case of the target Project's repo having its own gem
        # dependencies. As we don't isolate the build process by now, we have to inject
        # those dependencies into the CI system in order to work fine.
        # The first step is to make a snapshot of the current state of the CI's Gemfile and Gemfile.lock
        original_gemfile_contents = File.read(Bundler.default_gemfile)
        original_lockfile_contents = File.read(Bundler.default_lockfile)

        # We call the safe (because is synchronized) Bundler's `chdir` and
        # install all the dependencies, if any.
        Bundler::SharedHelpers.chdir(repo.local_folder) do
          ENV["FASTLANE_SKIP_DOCS"] = true.to_s

          gemfile_found = Dir[File.join(Dir.pwd, "**", "Gemfile")].any?
          if gemfile_found
            begin
              gemfile_dir = Dir[File.join(Dir.pwd, "**", "Gemfile")].first

              # In case the target repo has its own Gemfile, we parse its contents
              builder = Bundler::Dsl.new
              builder.eval_gemfile(gemfile_dir)

              # We already use local fastlane, so don't try to install it.
              project_dependencies = builder.dependencies.reject { |d| d.name == "fastlane" }

              # Inject all other dependencies that might be needed by the target.
              added = Bundler::Injector.inject(project_dependencies, {})
              if added.any?
                logger.info("Added to Gemfile:")
                logger.info(added.map do |d|
                  name = "'#{d.name}'"
                  requirement = ", '#{d.requirement}'"
                  group = ", :group => #{d.groups.inspect}" if d.groups != Array(:default)
                  source = ", :source => '#{d.source}'" unless d.source.nil?
                  %(gem #{name}#{requirement}#{group}#{source})
                end.join("\n"))
              end

              # Install the new Bundle and require all the new gems into the runtime.
              Bundler::Installer.install(Bundler.root, Bundler.definition)
              Bundler.require
            rescue Bundler::GemfileNotFound, Bundler::GemNotFound => ex
              logger.info(ex)
            rescue Gem::LoadError => ex
              logger.error(ex)
            rescue StandardError => ex
              logger.error(ex)
              logger.error(ex.backtrace)
            end
          end

          begin
            # Run fastlane now
            Fastlane::LaneManager.cruise_lane(
              platform,
              lane,
              parameters,
              nil,
              fast_file_path
            )
          rescue StandardError => ex
            # TODO: refactor this to reduce duplicate code
            logger.debug("Setting build status to error from fastlane")
            current_build.status = :failure
            current_build.description = "Build failed"

            logger.error(ex)
            logger.error(ex.backtrace)

            new_line_block.call(convert_raw_row_to_object({
              type: "crash",
              message: ex.to_s,
              time: Time.now
            }))
            ci_output.output_listeners.each do |listener|
              listener.error(ex.to_s)
            end
            artifacts_paths = gather_build_artifact_paths(loggers: [verbose_log, info_log])

            return
          ensure
            if gemfile_found
              # This is te step for recovering the pre-build dependency graph for the CI
              # The first step is to write the snapshot we made at the start of the build.
              File.write(Bundler.default_gemfile, original_gemfile_contents)
              File.write(Bundler.default_lockfile, original_lockfile_contents)
              # Our bundle runtime already has the build's gems installed and loaded, so
              # we have to clean the whole Bundle.
              Bundler.load.clean(true)
              Bundler.reset!
              # Finally, we install the new runtime and require it to load the CI's dependencies
              # as they were before the build.
              Bundler::Plugin.gemfile_install(Bundler.default_gemfile)
              definition = Bundler.definition
              definition.validate_runtime!
              Bundler::Installer.install(Bundler.root, definition, { dry_run: true })
              Bundler.require
            end
          end
        end

        current_build.status = :success
        current_build.description = "All green"
        logger.info("fastlane run complete")

        artifacts_paths = gather_build_artifact_paths(loggers: [verbose_log, info_log])
      rescue StandardError => ex
        logger.debug("Setting build status to failure due to exception")
        current_build.status = :ci_problem
        current_build.description = "fastlane.ci encountered an error, check fastlane.ci logs for more information"

        logger.error(ex)
        logger.error(ex.backtrace)

        # Catching the exception with this rescue block is really important,
        # as we also need to notify the listeners about it
        # see https://github.com/fastlane/ci/issues/583 for more details
        # notify all interested parties here
        # TODO: the line below could be improved
        #   right now we're just setting everything to `crash`
        #   to indicate this is causes a build failure
        new_line_block.call(convert_raw_row_to_object({
          type: "crash",
          message: ex.to_s,
          time: Time.now
        }))
        ci_output.output_listeners.each do |listener|
          listener.error(ex.to_s)
        end

        artifacts_paths = gather_build_artifact_paths(loggers: [verbose_log, info_log])
      ensure
        # TODO: what happens if `rescue` causes an exception
        completion_block.call(artifacts_paths)
      end
    end

    def convert_raw_row_to_object(raw_row)
      # Additionally to transfering the original metadata of this message
      # that look like this:
      #
      #   {:type=>:success, :message=>"Everything worked", :time=>...}
      #
      # we append the HTML code that should be used in the `html` key
      # the result looks like this
      #
      #   {
      #     "type": "success",
      #     "message": "Driving the lane 'ios beta'",
      #     "html": "<p class=\"success\">Driving the lane 'ios beta'</p>",
      #     "time" => ...
      #   }
      #
      # Also we use our custom BuildRunnerOutputRow class to represent the current row
      current_row = FastlaneCI::BuildRunnerOutputRow.new(
        type: raw_row[:type],
        message: raw_row[:message],
        time: raw_row[:time]
      )
      current_row.html = FastlaneOutputToHtml.convert_row(current_row)
      return current_row
    end

    protected

    def gather_build_artifact_paths(loggers:)
      artifact_paths = []
      loggers.each do |current_logger|
        next unless File.exist?(current_logger.file_path)
        artifact_paths << {
          type: File.basename(current_logger.file_path),
          path: File.expand_path(current_logger.file_path)
        }
      end
      constants_with_path =
        Fastlane::Actions::SharedValues.constants
                                       .select { |value| value.to_s.include?("PATH") } # Far from ideal
                                       .select do |value|
                                         !Fastlane::Actions.lane_context[value].nil? &&
                                           !Fastlane::Actions.lane_context[value].empty?
                                       end
                                       .map do |value|
                                         { type: value.to_s, path: Fastlane::Actions.lane_context[value] }
                                       end
      return artifact_paths.concat(constants_with_path)
    end
  end
end
