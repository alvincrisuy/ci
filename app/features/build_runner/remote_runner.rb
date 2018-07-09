require_relative "../../../agent/client"
require_relative "../../../lib/notifications"

module FastlaneCI
  ##
  # RemoteRunner
  #
  # This class will connect to a running Agent (provided by the grpc parameter)
  # and execute a fastlane command, streaming back the responses.
  # It can also provide an interface for anyone to listen to updates from the GRPC service.
  class RemoteRunner
    include FastlaneCI::Logging

    ##
    # `history` keeps a record of all of the notifications that were published to subscribers during a run.
    # this is used when a new subscriber `#subscribe`s to the Runner, they will be notified of all past messages.
    attr_reader :history

    # Reference to the FastlaneCI::Project of this particular build run
    attr_reader :project

    # In case we need to fork, we can configure the git repo
    attr_reader :git_fork_config

    # Access the FastlaneCI::Build of that specific Runner
    attr_reader :current_build

    # The commit sha we want to run the build for
    attr_reader :sha

    # TODO: extract this thing out of this class.
    attr_reader :github_service

    # TODO(snatchev): consider how to reduce the number of dependencies to this class.
    def initialize(project:, git_fork_config:, trigger:, github_service:, grpc: Agent::Client.new("localhost"))
      @project = project
      @git_fork_config = git_fork_config
      @github_service = github_service
      @current_build = prepare_build_object(trigger: trigger)
      @grpc = grpc

      @history = [] # TODO: consider implications if history becomes really large.
      @complete = false
      @completion_blocks = [] # TODO(snatchev): does this needs to be a threadsafe array?

      # This build needs to be saved during initialization because
      # RemoteRunner.start is called by a TaskQueue and could potentially
      # happen after the BuildController tries to fetch this build.
      save_build_status_locally!
    end

    def start
      env = environment_variables_for_worker
      start_time = Time.now.utc

      responses = @grpc.request_run_fastlane("bundle", "exec", "fastlane", project.platform, project.lane, env: env)
      responses.each do |response|
        # update the build's duration every time we get a message from the runner.
        current_build.duration = Time.now.utc - start_time

        # dispatch to handler methods
        handle_log(response.log)           if response.log
        handle_state(response.state)       if response.state
        handle_error(response.error)       if response.error
        handle_artifact(response.artifact) if response.artifact
      end

      @complete = true
      @completion_blocks.each(&:call)
    end

    def completed?
      @complete == true
    end

    def on_complete(&block)
      @completion_blocks << block
    end

    ##
    # This will get called on every iteration since `state` has a default value of :PENDING.
    # Skip in that case.
    def handle_state(state)
      return if state == :PENDING

      logger.debug("handle state transition: #{state}")
      publish_to_all(state: state)

      # TODO(snatchev): we should have the build state be the same as the InvocationResponse::State enum
      case state
      when :RUNNING
        current_build.status = :running
      when :FINISHING
        current_build.status = :running
      when :REJECTED
        current_build.status = :ci_problem
      when :FAILED
        current_build.status = :failure
      when :BROKEN
        current_build.status = :failure
      when :SUCCEEDED
        current_build.status = :success
        current_build.description = "All green"
      else
        logger.error("unknown state #{state}")
      end

      save_build_status!
    end

    def handle_log(log)
      logger.debug("handle log: #{log.inspect}")
      publish_to_all(log: log.to_h)
    end

    def handle_error(error)
      logger.debug("handle error: #{error}")
      publish_to_all(error: error.to_h)
    end

    # handle artifact upload. Do not publish this to the subscribers.
    def handle_artifact(artifact)
      logger.debug("handle artifact: #{artifact.filename}")

      artifact_path = File.join(@artifacts_path, response.artifact.filename)
      artifact = current_build.artifacts.find { |a| a.reference == artifact_path }
      unless artifact
        current_build.artifacts << Artifact.new(
          type: response.artifact.filename,
          reference: artifact_path,
          provider: @project.artifact_provider
        )
      end

      # open (or create if it doesn't exist) the file for appending with binary data.
      File.open(artifact_path, "ab+") { |f| f.write(response.artifact.chunk) }
    end

    # subscribe will all send all historic data to the subscriber.
    # the yielded object will be an InvocationResponse object
    def subscribe(&block)
      logger.debug("subscribing listener to topic `#{topic_name}`")
      subscriber = FastlaneCI::Notifications.subscribe(topic_name, &block)

      replay_history_to(subscriber)

      # make sure we call completion blocks if a subscriber joins after we have completed.
      if completed?
        @completion_blocks.each(&:call)
      end

      return subscriber
    end

    def unsubscribe(subscriber)
      logger.debug("unsubscribing listener #{subscriber}")
      FastlaneCI::Notifications.unsubscribe(subscriber)
    end

    def topic_name
      ["remote_runner", project.id, current_build.number].join(".")
    end

    private

    def publish_to(subscriber, payload)
      notifier = FastlaneCI::Notifications.notifier
      notifier.publish(subscriber: subscriber, payload: payload)
    end

    def publish_to_all(payload)
      @history << payload
      notifier = FastlaneCI::Notifications.notifier
      notifier.publish(name: topic_name, payload: payload)
    end

    def replay_history_to(subscriber)
      @history.each do |payload|
        publish_to(subscriber, payload)
      end
    end

    # TODO(snatchev): move this into the service
    def prepare_build_object(trigger:)
      builds = Services.build_service.list_builds(project: project)

      if builds.count > 0
        new_build_number = builds.max_by(&:number).number + 1
      else
        new_build_number = 1 # We start with build number 1
      end

      FastlaneCI::Build.new(
        project: project,
        number: new_build_number,
        status: :pending,
        # Ensure we're using UTC because your server might have a different timezone.
        # While this isn't neccesary since timestamps are already UTC, it's good to message it here.
        # so that utc stuff is discoverable
        timestamp: Time.now.utc,
        duration: -1,
        trigger: trigger.type,
        lane: project.lane,
        platform: project.platform,
        git_fork_config: git_fork_config,
        # The versions of the build tools are set later one, after the repo was checked out
        # and we can read files like the `xcode-version` file
        build_tools: {}
      )
    end

    # TODO(snatchev): pull this into it's own class for more testability.
    def environment_variables_for_worker
      # Set the CI specific Environment variables first

      # We try to follow the existing formats
      # https://wiki.jenkins.io/display/JENKINS/Building+a+software+project
      env_mapping = {
        BUILD_NUMBER: current_build.number,
        JOB_NAME: project.project_name,
        WORKSPACE: project.local_repo_path,
        GIT_URL: git_fork_config.clone_url,
        GIT_SHA: current_build.sha,
        BUILD_URL: "https://fastlane.ci", # TODO: actually build the URL, we don't know our own host, right?
        CI_NAME: "fastlane.ci",
        CI: true,
        FASTLANE_SKIP_DOCS: true
      }

      if git_fork_config.branch.to_s.length > 0
        env_mapping[:GIT_BRANCH] = git_fork_config.branch.to_s # TODO: does this work?
      else
        env_mapping[:GIT_BRANCH] = "master" # TODO: use actual default branch?
      end

      # We need to duplicate some ENV variables
      env_mapping[:CI_BUILD_NUMBER] = env_mapping[:BUILD_NUMBER]
      env_mapping[:CI_BUILD_URL] = env_mapping[:BUILD_URL]
      env_mapping[:CI_BRANCH] = env_mapping[:GIT_BRANCH]
      # env_mapping[:CI_PULL_REQUEST] = nil # TODO: do we have the PR information here?

      # Now that we have the CI specific ENV variables, let's go through the ENV variables
      # the user defined in their configuration
      Services.environment_variable_service.environment_variables.each do |environment_variable|
        if env_mapping.key?(environment_variable.key.to_sym)
          # TODO: this is probably large enough of an issue to use the fastlane.ci
          #       notification system to show an error to the user
          logger.error("Overwriting CI specific environment variable of key #{environment_variable.key} - " \
            "this is not recommended")
        end
        env_mapping[environment_variable.key.to_sym] = environment_variable.value
      end

      # Now set the project specific environment variables
      project.environment_variables.each do |environment_variable|
        if env_mapping.key?(environment_variable.key.to_sym)
          # TODO: similar to above: better error handling, depending on what variable gets overwritten
          #       this might be a big deal
          logger.error("Overwriting CI specific environment variable of key #{environment_variable.key}")
        end
        env_mapping[environment_variable.key.to_sym] = environment_variable.value
      end

      # Here we'll set the branch specific environment variables once this is implemented
      # This might not be top priority for a v1

      return env_mapping.map { |k, v| [k.to_s, v.to_s] }.to_h

      # TODO: to add potentially
      # - BUILD_ID
      # - BUILD_TAG
    end

    # Responsible for updating the build status in our local config
    # and on GitHub
    #
    # TODO:(snatchev) this operation must be *Synchronous*
    # because we don't want to send a message to the subscribers before it's been persisted
    def save_build_status!
      # TODO: update so that we can strip out the SHAs that should never be attempted to be rebuilt
      save_build_status_locally!
      save_build_status_source!
    end

    def save_build_status_locally!
      # Create or update the local build file in the config directory
      Services.build_service.add_build!(
        project: project,
        build: current_build
      )

      # Commit & Push the changes to git remote
      FastlaneCI::Services.project_service.git_repo.commit_changes!

      # TODO: disabled for now so that while we developer we don't keep pushing to remote ci-config repo
      # FastlaneCI::Services.project_service.push_configuration_repo_changes!
    rescue StandardError => ex
      logger.error("Error setting the build status as part of the config repo")
      logger.error(ex)
      # If setting the build status inside the git repo fails
      # this is actually a big deal, and we can't proceed.
      # For setting the build status, if that fails, it's fine
      # as the source of truth is the git repo
      raise ex
    end

    # Let GitHub know about the current state of the build
    # Using a `rescue` block here is important
    # As the build is still green, even though we couldn't set the GH status
    def save_build_status_source!
      status_context = project.project_name

      build_path = FastlaneCI::BuildController.build_url(project_id: project.id, build_number: current_build.number)
      build_url = FastlaneCI.dot_keys.ci_base_url + build_path
      github_service.set_build_status!(
        repo: project.repo_config.git_url,
        sha: current_build.sha,
        state: current_build.status,
        target_url: build_url,
        status_context: status_context,
        description: current_build.description
      )
    rescue StandardError => ex
      logger.error("Error setting the build status on remote service")
      logger.error(ex)
    end
  end
end
