# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The checks proposed for a project no configured stack matches: read from the project's own files, fixed argv only,
# nothing run or written, and no proposal when there is nothing to prove a change with.

require_relative "../test_helper"
require "json"
require "tmpdir"

class SuggestTest < Minitest::Test
  S = Harness::Gates::Suggest

  def setup = @tmp = Dir.mktmpdir("harness-suggest-")
  def teardown = FileUtils.rm_rf(@tmp)

  def put(files)
    files.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(@tmp, rel)))
      File.write(File.join(@tmp, rel), text)
    end
  end

  def found(windows: false, **files)
    put(files)
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @tmp).sort
    out = S.for(@tmp, windows: windows)
    assert_equal before, Dir.glob("**/*", File::FNM_DOTMATCH, base: @tmp).sort, "nothing is written"
    Harness::Gates::Stack.parse("x", out.stack.merge("project" => @tmp)) if out # what is proposed is always valid config (I4, I10)
    out
  end

  def argv(out) = out.stack["gates"].transform_values { |g| g["argv"] }

  def test_a_ruby_project_with_its_own_check_script
    out = found("x.gemspec" => "", "bin/check" => "#!/usr/bin/env ruby\n", "test/a_test.rb" => "", "Rakefile" => "")
    assert_equal "Ruby", out.label
    assert_equal %w[ruby bin/check], argv(out)["check"]
    assert_equal "touched", out.stack["gates"]["unit"]["scope"]
    refute argv(out).key?("test"), "bin/check already runs the tests"
    assert_equal %w[check unit], out.stack["alwaysGates"].sort
  end

  def test_a_bundled_ruby_project_runs_its_tools_through_bundler
    assert_equal({ "unit" => ["bundle", "exec", "ruby", "-Ilib", "-Itest", "-e", S::RUBY_TESTS, "{files}"], "test" => %w[bundle exec rake test],
                   "spec" => %w[bundle exec rspec] },
                 argv(found("Gemfile" => "", "Gemfile.lock" => "", "Rakefile" => "", "test/a_test.rb" => "", "spec/a_spec.rb" => "")))
  end

  def test_package_scripts_become_checks_but_not_ones_that_watch_or_do_nothing
    pkg = { "scripts" => { "typecheck" => "tsc --noEmit", "lint" => "eslint --watch .", "test" => 'echo "Error: no test specified" && exit 1',
                           "build" => "vite build", "dev" => "vite", "deploy" => "x" }, "devDependencies" => { "typescript" => "^5" } }
    out = found("package.json" => JSON.generate(pkg), "pnpm-lock.yaml" => "")
    assert_equal "TypeScript", out.label
    assert_equal({ "typecheck" => %w[pnpm run typecheck], "build" => %w[pnpm run build] }, argv(out))
    assert_equal ["typecheck"], out.stack["alwaysGates"], "the build runs once, at the end"
    assert_equal ["node_modules"], out.stack["dependencyDirs"]
  end

  def test_a_typescript_project_without_scripts_gets_its_own_compiler
    out = found("package.json" => JSON.generate({ "devDependencies" => { "typescript" => "^5" } }), "tsconfig.json" => "{}")
    assert_equal({ "typecheck" => %w[npx --offline --no -- tsc --noEmit] }, argv(out))
  end

  def test_python_go_rust_and_make
    assert_equal %w[python3 -B -m pytest -q -p no:cacheprovider], argv(found("pyproject.toml" => "[tool.pytest]", "tests/test_a.py" => ""))["test"]
    assert_equal "python", argv(S.for(@tmp, windows: true))["test"].first
    teardown
    setup
    assert_equal %w[python3 -B -m unittest discover -s tests], argv(found("setup.py" => "", "tests/test_a.py" => ""))["test"]
    teardown
    setup
    assert_equal({ "vet" => %w[go vet -mod=readonly ./...], "test" => %w[go test -mod=readonly ./...] }, argv(found("go.mod" => "")))
    teardown
    setup
    assert_equal %w[cargo check --offline], argv(found("Cargo.toml" => ""))["check"]
    teardown
    setup
    assert_equal %w[make check], argv(found("Makefile" => "all:\n\tx\ncheck: all\n\ty\ntest:\n\tz\n"))["check"]
  end

  def test_two_kinds_in_one_project_keep_all_their_checks
    out = found("go.mod" => "", "package.json" => JSON.generate({ "scripts" => { "test" => "vitest run" } }))
    assert_equal "JavaScript and Go", out.label
    assert_equal %w[test unit vet], out.stack["gates"].keys.sort
  end

  def test_nothing_is_proposed_when_nothing_could_prove_a_change
    assert_nil found("index.html" => "<h1>Hi</h1>")
    assert_nil found("package.json" => "not json")
    assert_nil found("package.json" => JSON.generate({ "scripts" => { "dev" => "vite" } }), "README.md" => "")
    assert_nil found("Gemfile" => "", "test/a_test.rb" => ""), "touched tests alone prove nothing about a task that touches none"
    assert_nil found("Makefile" => "check := 1\n")
  end

  def test_a_stack_for_one_project_is_used_for_that_project_only
    put("a/go.mod" => "", "b/go.mod" => "", "copy/go.mod" => "")
    a, b, copy = %w[a b copy].map { |d| File.join(@tmp, d) }
    config = Harness::Config.parse({ "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:9/v1" } },
                                     "stacks" => { "a" => { "project" => a, "detect" => ["go.mod"] }, "gem" => { "detect" => ["*.gemspec"] } } })
    assert_equal "a", config.stack_for(a).name
    assert_nil config.stack_for(b), "its detect files do not matter once a stack is for one project"
    assert_equal "a", config.stack_for(copy, project: a).name, "a run's copy uses the checks of the project it is a copy of"
    assert_nil config.stack_for(copy)
    put("b/x.gemspec" => "")
    assert_equal "gem", config.stack_for(b).name, "a detect pattern matches"
    assert_raises(Harness::ParseError) { Harness::Gates::Stack.parse("x", { "project" => "relative/path" }) }
  end
end
