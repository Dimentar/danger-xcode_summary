# frozen_string_literal: true

require 'json'
require 'xcresult'

module Danger
  # Shows all build errors, warnings and unit tests results generated from `xcodebuild`.
  # You need to use the `xcresult` produced by Xcode 11. It's located in the Derived Data folder.
  # @example Showing summary
  #
  #          xcode_summary.report 'build.xcresult'
  #
  # @example Filtering warnings in Pods
  #
  #          xcode_summary.ignored_files = '**/Pods/**'
  #          xcode_summary.report 'build.xcresult'
  #
  # @see  diogot/danger-xcode_summary
  # @tags xcode, xcodebuild, format
  #
  class DangerXcodeSummary < Plugin
    Location = Struct.new(:file_name, :file_path, :line)
    Result = Struct.new(:message, :location)
    Warning = Struct.new(:message, :sticky, :location)

    # The project root, which will be used to make the paths relative.
    # Defaults to `pwd`.
    # @param    [String] value
    # @return   [String]
    attr_accessor :project_root

    # A globbed string or array of strings which should match the files
    # that you want to ignore warnings on. Defaults to nil.
    # An example would be `'**/Pods/**'` to ignore warnings in Pods that your project uses.
    #
    # @param    [String or [String]] value
    # @return   [[String]]
    attr_accessor :ignored_files

    # A block that filters specific results.
    # An example would be `lambda { |result| result.message.start_with?('ld') }` to ignore results for ld_warnings.
    #
    # @param    [Block] value
    # @return   [Block]
    attr_accessor :ignored_results

    # Defines if the test summary will be sticky or not.
    # Defaults to `false`.
    # @param    [Boolean] value
    # @return   [Boolean]
    attr_accessor :sticky_summary

    # Defines if the build summary is shown or not.
    # Defaults to `true`.
    # @param    [Boolean] value
    # @return   [Boolean]
    attr_accessor :test_summary

    # A block that sorts the warning results.
    # An example would be `lambda { |warning| warning.message.include?("deprecated") ? 1 : 0 }` to sort results for
    # deprecated warnings.
    #
    # @param    [Block] value
    # @return   [Block]
    attr_accessor :sort_warnings_by

    # Defines if using inline comment or not.
    # Defaults to `false`.
    # @param    [Boolean] value
    # @return   [Boolean]
    attr_accessor :inline_mode

    # Defines if warnings should be included or not
    # Defaults to `false`.
    # @param    [Boolean] value
    # @return   [Boolean]
    attr_accessor :ignores_warnings

    # Defines errors strict. If value is `false`, then errors will be reporting as warnings.
    # Defaults to `true`
    # @param    [Boolean] value
    # @return   [Boolean]
    attr_accessor :strict

    # Defines errors message length limit. If value is `nil`, then errors will be reporting full message.
    # Defaults to `nil`
    # @param    [Integer] value
    # @return   [Integer]
    attr_accessor :message_length_limit

    # Extracts Succeseful tests from TestPlanSummaries.
    # Defaults to `[]`
    # @param    [String] value
    # @return   [String]
    attr_accessor :success_test_ids

    # rubocop:disable Lint/DuplicateMethods
    def project_root
      root = @project_root || Dir.pwd
      root += '/' unless root.end_with? '/'
      root
    end

    def ignored_files
      [@ignored_files].flatten.compact
    end

    def sort_warnings_by(&block)
      @sort_warnings_by ||= block
    end

    def ignored_results(&block)
      @ignored_results ||= block
    end

    def sticky_summary
      @sticky_summary || false
    end

    def test_summary
      @test_summary.nil? ? true : @test_summary
    end

    def inline_mode
      @inline_mode || false
    end

    def ignores_warnings
      @ignores_warnings || false
    end

    def strict
      @strict.nil? ? true : @strict
    end

    def message_length_limit
      @message_length_limit.nil? ? -1 : @message_length_limit
    end

    def success_test_ids
      @success_test_ids.nil? ? [] : @success_test_ids
    end

    # Pick a Dangerfile plugin for a chosen request_source and cache it
    # based on https://github.com/danger/danger/blob/master/lib/danger/plugin_support/plugin.rb#L31
    #
    # @return   [void]
    def plugin
      plugins = Plugin.all_plugins.select { |plugin| Dangerfile.essential_plugin_classes.include? plugin }
      @plugin ||= plugins.select { |p| p.method_defined? :html_link }.map { |p| p.new(@dangerfile) }.compact.first
    end
    # rubocop:enable Lint/DuplicateMethods

    # Reads a `.xcresult` and reports it.
    #
    # @param    [String] file_path Path for xcresult bundle.
    # @return   [void]
    def report(file_path)
      if File.exist?(file_path)
        xcode_summary = XCResult::Parser.new(path: file_path)
        format_summary(xcode_summary)
      else
        fail 'summary file not found'
      end
    end

    # Reads a `.xcresult` and reports its warning and error count.
    #
    # @param    [String] file_path Path for xcresult bundle.
    # @return   [String] JSON string with warningCount and errorCount
    def warning_error_count(file_path)
      if File.exist?(file_path)
        xcode_summary = XCResult::Parser.new(path: file_path)
        warning_count = 0
        error_count = 0
        xcode_summary.actions_invocation_record.actions.each do |action|
          warning_count += warnings(action).count
          error_count += errors(action).count
        end
        result = { warnings: warning_count, errors: error_count }
        result.to_json
      else
        fail 'summary file not found'
      end
    end

    private

    def format_summary(xcode_summary)
      extract_success_test_ids(xcode_summary)
      messages(xcode_summary).each { |s| message(s, sticky: sticky_summary) }
      all_warnings = []
      xcode_summary.actions_invocation_record.actions.each do |action|
        warnings(action).each do |result|
          warning_object = nil
          if inline_mode && result.location
            warning_object = Warning.new(result.message, false, result.location)
          else
            warning_object = Warning.new(result.message, false, nil)
          end
          all_warnings << warning_object
        end
        errors(action).each do |result|
          if inline_mode && result.location
            if strict
              fail(result.message, sticky: false, file: result.location.file_path, line: result.location.line)
            else
              warn(result.message, sticky: false, file: result.location.file_path, line: result.location.line)
            end
          else
            if strict
              fail(result.message, sticky: false)
            else
              warn(result.message, sticky: false)
            end
          end
        end
      end
      sort_and_log_warnings(all_warnings)
    end

    def sort_and_log_warnings(all_warnings)
      all_warnings = all_warnings.sort_by(&sort_warnings_by)
      all_warnings.each do |warning|
        if inline_mode && warning.location
          warn(warning.message, sticky: warning.sticky, file: warning.location.file_path, line: warning.location.line)
        else
          warn(warning.message, sticky: warning.sticky)
        end
      end
    end

    def messages(xcode_summary)
      if test_summary
        test_messages = xcode_summary.action_test_plan_summaries.map do |test_plan_summaries|
          test_plan_summaries.summaries.map do |summary|
            summary.testable_summaries.map do |test_summary|
              test_summary.tests.filter_map do |action_test_object|
                if action_test_object.instance_of? XCResult::ActionTestSummaryGroup
                  subtests = action_test_object.all_subtests
                  subtests_duration = subtests.map(&:duration).sum
                  test_text_infix = subtests.count == 1 ? 'test' : 'tests'
                  failed_tests_count = subtests.reject { |test| test.test_status == 'Success' }.count
                  expected_failed_tests_count = subtests.select { |test| test.test_status == 'Expected Failure' }.count

                  "#{test_summary.target_name}: Executed #{subtests.count} #{test_text_infix}, " \
                    "with #{failed_tests_count} failures (#{expected_failed_tests_count} expected) in " \
                    "#{subtests_duration.round(3)} (#{action_test_object.duration.round(3)}) seconds"
                end
              end
            end
          end
        end
        test_messages.flatten.uniq.compact.map(&:strip)
      else
        []
      end
    end

    def extract_success_test_ids(xcode_summary)
      xcode_summary.action_test_plan_summaries.map do |test_plan_summaries|
        test_plan_summaries.summaries.map do |summary|
          summary.testable_summaries.map do |test_summary|
            test_summary.tests.filter_map do |action_test_object|
              if action_test_object.instance_of? XCResult::ActionTestSummaryGroup
                action_test_object.subtests.filter_map do |subtest|
                  @success_test_ids = subtest.subtests.flat_map do |s|
                    s.subtests.select { |test| test.test_status == 'Success' }.map do |test|
                      test.identifier.gsub('/', '.')
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def warnings(action)
      return [] if ignores_warnings

      warnings = [
        action.action_result.issues.warning_summaries,
        action.build_result.issues.warning_summaries
      ].flatten.compact.map do |summary|
        result = Result.new(summary.message, parse_location(summary.document_location_in_creating_workspace))
        Result.new(format_warning(result), result.location)
      end
      warnings = warnings.uniq.reject { |result| result.message.nil? }
      warnings.delete_if(&ignored_results)
    end

    def errors(action)
      errors = [
        action.action_result.issues.error_summaries,
        action.build_result.issues.error_summaries
      ].flatten.compact.map do |summary|
        result = Result.new(summary.message, parse_location(summary.document_location_in_creating_workspace))
        Result.new(format_warning(result), result.location)
      end

      if action.action_result.status == 'succeeded'
        results = errors.uniq(&:message).reject { |result| result.message.nil? }
      else
        test_failures = [
          action.action_result.issues.test_failure_summaries,
          action.build_result.issues.test_failure_summaries
        ].flatten.compact.map do |summary|
          if @success_test_ids.include?(summary.test_case_name)
            nil
          else
            result = Result.new(summary.message, parse_location(summary.document_location_in_creating_workspace))
            Result.new(format_test_failure(result, summary.producing_target, summary.test_case_name), result.location)
          end
        end
        results = (errors + test_failures).compact.uniq(&:message).reject { |result| result.message.nil? }
      end

      results.delete_if(&ignored_results)
    end

    def parse_location(document_location)
      return nil if document_location&.url.nil?

      file_path = document_location.url.gsub('file://', '').split('#').first
      file_name = file_path.split('/').last
      fragment = document_location.url.split('#').last
      params = CGI.parse(fragment).transform_values(&:first)
      line_number = params['StartingLineNumber']
      # StartingLineNumber is 0-based, but we need a 1-based value
      line = line_number.nil? || line_number.empty? ? 0 : line_number.to_i + 1
      Location.new(file_name, relative_path(file_path), line)
    end

    def format_path(file_path, line)
      if plugin
        path = file_path
        path += "#L#{line}" if line
        plugin.html_link(path)
      else
        file_path
      end
    end

    def relative_path(path)
      return nil if project_root.nil?

      path.gsub(project_root, '')
    end

    def should_ignore_warning?(path)
      ignored_files.any? { |pattern| File.fnmatch(pattern, path) }
    end

    def escape_reason(reason)
      reason.gsub('>', '\>').gsub('<', '\<')
    end

    def format_warning(result)
      return escape_reason(result.message) if result.location.nil?

      path = result.location.file_path
      return nil if should_ignore_warning?(path)

      path_link = format_path(path, result.location.line)

      "**#{path_link}**: #{escape_reason(result.message)}"
    end

    def format_test_failure(result, producing_target, test_case_name)
      # Substituting the pid for test retryies to filter them later.
      message = result.message
      message = message.sub(/, given input App element pid: \d{3,6}/, '.')
      message = message.gsub("\n", ' ').gsub("\r", ' ').strip
      if message_length_limit >= 0
        message = message[0, message_length_limit]
        message += '...'
      end
      return escape_reason(message) if result.location.nil?

      path = result.location.file_path
      path_link = format_path(path, result.location.line)
      if producing_target.nil? || producing_target.empty?
        suite_name = "#{test_case_name}"
      else
        suite_name = "#{producing_target}.#{test_case_name}"
      end
      "**#{suite_name}**: #{escape_reason(message)}  <br />  #{path_link}"
    end
  end
end
