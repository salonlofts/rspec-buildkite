require "thread"

require "rspec/core"
require "rspec/buildkite/recolorizer"

module RSpec::Buildkite
  # Create a Buildkite annotation for RSpec failures
  #
  # Help folks fix their builds as soon as possible when failures crop up by
  # calling out failures in an annotation, even while the build is still running.
  #
  # Uses a background Thread so we don't block the build.
  #
  class AnnotationFormatter < RSpec::Core::Formatters::BaseFormatter
    # RSpec::Core::Formatters.register self, :example_failed

    def initialize(output)
      # We don't actually use this, but keep a reference anyway
      # @output = output
      @output = output || StringIO.new
      @example_count = @pending_count = @failure_count = 0
      @examples = []
      @failed_examples = []
      @pending_examples = []
      @example_group = nil

      # Only setup if we're actually running on Buildkite
      if ENV["BUILDKITE"]
        @queue = Queue.new
        @thread = Thread.new(&method(:thread))
        at_exit { @queue.push(:close); @thread.join }
      end
    end

    def example_failed(notification)
      @queue.push(notification) if @queue
    end

    private

    def thread
      while notification = @queue.pop
        break if notification == :close

        if notification
          system("buildkite-agent", "annotate",
            "--context", "rspec",
            "--style", "error",
            "--append",
            format_failure(notification),
            out: :close # only display errors
          ) or raise "buildkite-agent failed to run: #{$?}#{" (command not found)" if $?.exitstatus == 127}"
        end
      end
    rescue
      $stderr.puts "Warning: Couldn't create Buildkite annotations:\n" <<
        "  #{$!.to_s}\n" <<
        "    #{$!.backtrace.join("\n    ")}"
    end

    def format_failure(notification)
      build_url = ENV["BUILDKITE_BUILD_URL"].to_s
      job_id = ENV["BUILDKITE_JOB_ID"].to_s
      job_url = "#{build_url}##{job_id}"

      exception = notification.exception
      message = exception.message
      formatted_backtrace = format_backtrace(exception.backtrace, notification)
      exception_message = "#{message}\n#{formatted_backtrace.join("\n")}"

      %{<details>\n} <<
      %{<summary>:rspec:#{notification.description.encode(:xml => :text)}</summary>\n} <<
      %{<pre class="term">#{exception_message.encode(:xml => :text)}</pre>\n} <<
      format_rerun(notification) <<
      %{<p>in <a href=#{job_url.encode(:xml => :attr)}>Job ##{job_id.encode(:xml => :text)}</a></p>\n} <<
      format_artifacts(notification) <<
      %{</details>} <<
      %{\n\n\n}

      # %{<details>\n} <<
      # %{<summary>#{notification.description.encode(:xml => :text)}</summary>\n} <<
      # %{<pre class="term">#{Recolorizer.recolorize(notification.colorized_message_lines.join("\n").encode(:xml => :text))}</pre>\n} <<
      # format_rerun(notification) <<
      # %{<p>in <a href=#{job_url.encode(:xml => :attr)}>Job ##{job_id.encode(:xml => :text)}</a></p>\n} <<
      # %{</details>} <<
      # %{\n\n\n}
    end

    def format_artifacts(notification)
      return "" unless notification.metadata[:screenshot]

      screenshot = notification.metadata[:screenshot]
      image_relative_path = screenshot[:image].sub(/\A#{Rails.root}\/?/, '')
      html_relative_path = screenshot[:html].sub(/\A#{Rails.root}\/?/, '')
      image_path = "artifact://#{image_relative_path}"
      html_path = "artifact://#{html_relative_path}"

      %{<p><a href=#{html_path.encode(:xml => :attr)} target="_blank">Screenshot HTML</a></p>\n} <<
      %{<img src=\"#{image_path.encode(:xml => :text)}\">\n}
    end

    def format_rerun(notification)
      %{<pre class="term">} <<
      %{<p><span class="term-fg31">rspec #{RSpec::Core::Metadata::relative_path(notification.location).encode(:xml => :text)}</span></p>} <<
      %{<p><span class="term-fg36"># #{notification.full_description.encode(:xml => :text)}</span></p>} <<
      %{</pre>\n}

      # %{<pre class="term">} <<
      # %{<span class="term-fg31">rspec #{notification.example.location_rerun_argument.encode(:xml => :text)}</span>} <<
      # %{ <span class="term-fg36"># #{notification.example.full_description.encode(:xml => :text)}</span>} <<
      # %{</pre>\n}
    end
  end
end
