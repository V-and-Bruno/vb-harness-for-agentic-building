# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"

module Harness
  module Gates
    # The checks a project already has, as a stack for config.json: for projects no configured stack matches. It reads
    # a few well-known files (package.json, Gemfile, pyproject.toml, go.mod, Cargo.toml, Makefile) and builds fixed
    # argv from them. Nothing is run, installed or written here. The app shows the exact commands and writes the stack
    # only after the user confirms, so a run still runs only commands from config (I3). A project with no checks gets
    # no suggestion: there would be nothing to prove a change with (I7).
    module Suggest
      # label: the kind of project, for people; stack: the raw config hash (see Gates::Stack), without "project".
      Found = Data.define(:label, :stack)

      MAX_FILE = 512 * 1024
      PROTECTED = [".git/**", ".github/**", ".env*", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock",
                   "Gemfile.lock", "poetry.lock", "uv.lock", "go.sum", "Cargo.lock"].freeze
      # package.json scripts that check, by gate, in the order they are looked for. Never a script that watches.
      SCRIPTS = { "typecheck" => %w[typecheck type-check check-types check:types], "lint" => %w[lint], "check" => %w[check],
                  "unit" => %w[test:unit test], "build" => %w[build] }.freeze
      WATCHES = /--watch(?!=false|All=false)|\s-w\b|\bnodemon\b/
      # What npm init writes when there are no tests.
      NO_TESTS = /no test specified/
      LOCKFILES = { "pnpm-lock.yaml" => "pnpm", "yarn.lock" => "yarn" }.freeze
      # Loads the test files it is given; {files} may hold other files too.
      RUBY_TESTS = "ARGV.grep(/_test\\.rb\\z/).each { |f| require File.expand_path(f) }"
      MAKE_TARGETS = %w[check test].freeze

      # @param root [String] the project's top folder
      # @param windows [Boolean] whether commands will run on Windows (the Python command differs)
      # @return [Found, nil] nil when the project has no checks this knows
      def self.for(root, windows: Gem.win_platform?)
        parts = [node(root), ruby(root), python(root, windows), go(root), rust(root)].compact
        parts = [make(root)].compact if parts.empty?
        return nil if parts.empty?

        gates = parts.each_with_object({}) do |part, out|
          part[:gates].each { |name, gate| out[out.key?(name) ? "#{part[:label].downcase}-#{name}" : name] = gate }
        end
        labels = parts.map { |p| p[:label] }
        stack = { "framework" => { "name" => labels.first }, "dependencyDirs" => parts.flat_map { |p| p[:dirs] || [] },
                  "gates" => gates, "alwaysGates" => gates.reject { |_, g| g["when"] == "integration" }.keys, "protectedPaths" => PROTECTED }
        Found.new(label: labels.join(" and "), stack: stack)
      end

      # @param stack [Hash] a raw stack
      # @return [Array<String>] one line per check, "name: command", for the confirm dialog
      def self.lines(stack)
        stack["gates"].map { |name, g| "#{name}: #{g['argv'].map { |a| a.match?(/[\s*?()|;&]/) ? "\"#{a}\"" : a }.join(' ')}" }
      end

      # @return [Hash, nil]
      def self.node(root)
        pkg = json(root, "package.json") or return nil
        scripts = pkg["scripts"].is_a?(Hash) ? pkg["scripts"] : {}
        manager = LOCKFILES.find { |f, _| file?(root, f) }&.last || "npm"
        gates = {}
        SCRIPTS.each do |gate, names|
          name = names.find { |n| scripts[n].is_a?(String) && !scripts[n].match?(WATCHES) && !scripts[n].match?(NO_TESTS) }
          next unless name

          gates[gate] = { "argv" => [manager, "run", name], "scope" => "project", "costRank" => gates.size + 2 }
          gates[gate].merge!("when" => "integration", "costRank" => 8) if gate == "build"
        end
        if !gates.key?("typecheck") && !gates.key?("check") && file?(root, "tsconfig.json") && dependency?(pkg, "typescript")
          gates["typecheck"] = { "argv" => %w[npx --offline --no -- tsc --noEmit], "scope" => "project", "parser" => "tsc", "costRank" => 2 }
        end
        return nil if gates.empty?

        installs = %w[dependencies devDependencies].any? { |k| pkg[k].is_a?(Hash) && !pkg[k].empty? }
        { label: dependency?(pkg, "typescript") ? "TypeScript" : "JavaScript", gates: gates, dirs: installs ? ["node_modules"] : [] }
      end

      # @return [Hash, nil]
      def self.ruby(root)
        return nil unless file?(root, "Gemfile") || file?(root, "Rakefile") || Dir.glob("*.gemspec", base: root).any? || ruby_script?(root, "bin/check")

        bundled = file?(root, "Gemfile.lock") ? %w[bundle exec] : []
        gates = {}
        gates["check"] = { "argv" => %w[ruby bin/check], "scope" => "project", "costRank" => 6, "timeoutSec" => 1800 } if ruby_script?(root, "bin/check")
        if Dir.glob("test/**/*_test.rb", base: root).any?
          gates["unit"] = { "argv" => [*bundled, "ruby", "-Ilib", "-Itest", "-e", RUBY_TESTS, "{files}"], "scope" => "touched", "costRank" => 2 }
          gates["test"] = { "argv" => [*bundled, "rake", "test"], "scope" => "project", "costRank" => 5 } if gates["check"].nil? && file?(root, "Rakefile")
        end
        gates["spec"] = { "argv" => [*bundled, "rspec"], "scope" => "project", "costRank" => 5 } if Dir.glob("spec/**/*_spec.rb", base: root).any?
        # Touched tests alone prove nothing about a task that touches none.
        return nil unless gates.any? { |_, g| g["scope"] == "project" }

        { label: "Ruby", gates: gates }
      end

      # @return [Hash, nil]
      def self.python(root, windows)
        meta = %w[pyproject.toml setup.cfg requirements.txt requirements-dev.txt pytest.ini tox.ini].map { |f| read(root, f).to_s }.join("\n")
        return nil if meta.empty? && !file?(root, "setup.py")

        command = windows ? "python" : "python3"
        tests = Dir.glob("{tests,test}/**/{test_*,*_test}.py", base: root)
        return nil if tests.empty? && Dir.glob("{test_*,*_test}.py", base: root).empty?

        runner = meta.match?(/\bpytest\b/) ? %w[pytest -q -p no:cacheprovider] : ["unittest", "discover", *(tests.empty? ? [] : ["-s", tests.first.split("/").first])]
        { label: "Python", gates: { "test" => { "argv" => [command, "-B", "-m", *runner], "scope" => "project", "costRank" => 5 } } }
      end

      # @return [Hash, nil]
      def self.go(root)
        return nil unless file?(root, "go.mod")

        { label: "Go", gates: { "vet" => { "argv" => %w[go vet -mod=readonly ./...], "scope" => "project", "costRank" => 2 },
                                "test" => { "argv" => %w[go test -mod=readonly ./...], "scope" => "project", "costRank" => 5 } } }
      end

      # @return [Hash, nil]
      def self.rust(root)
        return nil unless file?(root, "Cargo.toml")

        { label: "Rust", gates: { "check" => { "argv" => %w[cargo check --offline], "scope" => "project", "costRank" => 2 },
                                  "test" => { "argv" => %w[cargo test --offline], "scope" => "project", "costRank" => 5 } } }
      end

      # @return [Hash, nil]
      def self.make(root)
        text = read(root, "Makefile") or return nil
        target = MAKE_TARGETS.find { |t| text.match?(/^#{t}\s*:(?!=)/) } or return nil
        { label: "Make", gates: { target => { "argv" => ["make", target], "scope" => "project", "costRank" => 5 } } }
      end

      # @return [Boolean]
      def self.dependency?(pkg, name) = %w[dependencies devDependencies].any? { |k| pkg[k].is_a?(Hash) && pkg[k].key?(name) }

      # @return [Boolean] an executable-style Ruby script at rel
      def self.ruby_script?(root, rel) = read(root, rel).to_s.lines.first.to_s.match?(/\A#!.*\bruby\b/)

      # @return [Boolean]
      def self.file?(root, rel) = File.file?(File.join(root, rel))

      # @return [String, nil] a file's text, or nil when it is missing, too large or unreadable
      def self.read(root, rel)
        full = File.join(root, rel)
        return nil unless File.file?(full) && File.size(full) <= MAX_FILE

        File.binread(full).force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError
        nil
      end

      # @return [Hash, nil]
      def self.json(root, rel)
        data = JSON.parse(read(root, rel).to_s)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end
      private_class_method :node, :ruby, :python, :go, :rust, :make, :dependency?, :ruby_script?, :file?, :read, :json
    end
  end
end
