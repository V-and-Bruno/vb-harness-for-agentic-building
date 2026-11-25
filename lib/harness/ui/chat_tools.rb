# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../agent/toolbox"
require_relative "../errors"
require_relative "../repo/git"
require_relative "../untrusted"

module Harness
  module UI
    # What Chat may read of the one project the user picked: the agent's reading tools, over the files git tracks and
    # nothing else. A run works in a copy that holds only committed files; Chat reads the user's own folder, where
    # untracked files may be private, so those and files that look like secrets are not there for it at all. Nothing
    # is written or run, and every result is fenced (I9).
    class ChatTools
      NAMES = %w[read_file list_dir search find_symbol].freeze
      # Never shown, even when tracked by mistake.
      SECRETS = %w[.env* **/.env* **/*.pem **/*.key **/*.p12 **/*.pfx **/id_rsa* **/id_ed25519* **/.npmrc **/.netrc **/.pypirc **/credentials*
                   **/*.keystore **/*.tfstate*].freeze
      MAX_CALLS = 12

      # One call, for the page and the saved chat. target: the path, text or name it was about.
      Step = Data.define(:tool, :target, :ok) do
        # @return [Hash]
        def to_json_hash = to_h.transform_keys(&:to_s)
      end

      # @return [Array<Step>]
      attr_reader :steps

      # @param root [String] the project's top folder
      # @param stack [Gates::Stack, nil]
      # @param settings [Agent::Settings]
      # @param git [Repo::Git]
      # @param room [Integer] characters of results that fit the conversation
      # @raise [GitError] when git cannot list the project's files
      def initialize(root:, stack:, settings:, git:, room:)
        tracked = git.run(%w[ls-files -z --cached], chdir: root).split("\0").map { |f| f.dup.force_encoding(Encoding::UTF_8).scrub }
        @toolbox = Agent::Toolbox.new(root: root, protected: (stack&.protected_paths || []).reject { |p| lockfile?(p) } + SECRETS,
                                      stack: stack, settings: settings, visible: tracked)
        @room = room
        @steps = []
      end

      # @return [Array<Hash>] OpenAI tool definitions
      def definitions = @toolbox.definitions.select { |d| NAMES.include?(d.dig("function", "name")) }

      # @return [Boolean] whether another call may be made
      def more? = @steps.size < MAX_CALLS && @room.positive?

      # Run one call the model asked for. A bad call gets an error text, never an exception.
      # @param name [String]
      # @param arguments [String, Hash] as the model sent them
      # @return [String] the fenced result
      def call(name, arguments)
        args = arguments.is_a?(Hash) ? arguments : JSON.parse(arguments.to_s.empty? ? "{}" : arguments)
        raise JSON::ParserError, "not an object" unless args.is_a?(Hash)
        return refuse(name, "error: there is no tool #{name.to_s[0, 40].inspect} here; Chat only reads") unless NAMES.include?(name)
        return refuse(name, "error: no more reading in this reply; answer with what you have") unless more?

        out = @toolbox.call(name, args)
        done = @toolbox.calls.last
        @steps << Step.new(tool: name, target: (args["path"] || args["text"] || args["name"]).to_s[0, 120], ok: done.ok)
        out = Untrusted.fence("error: this result does not fit; ask for fewer lines, or a narrower search") if out.size > @room
        @room -= out.size
        out
      rescue JSON::ParserError
        refuse(name, "error: the arguments must be one JSON object")
      end

      private

      # A lockfile is protected from writing; reading it is harmless.
      def lockfile?(pattern) = pattern.match?(/lock/i)

      def refuse(name, text)
        @steps << Step.new(tool: name.to_s[0, 40], target: "", ok: false)
        Untrusted.fence(text)
      end
    end
  end
end
