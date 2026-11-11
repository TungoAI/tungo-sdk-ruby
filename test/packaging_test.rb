# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

# The gem as a package: version, entry points, declared dependencies, examples, README.
class PackagingTest < TungoTestCase
  GEMSPEC = Gem::Specification.load(File.join(ROOT, "tungo-sdk.gemspec"))

  def ruby(*)
    output, status = Open3.capture2e(RbConfig.ruby, "-W:deprecated", "-w", *, chdir: ROOT)

    assert_predicate status, :success?, output
    output
  end

  def test_version
    assert_match(/\A\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\z/, Tungo::VERSION)
    assert_equal Tungo::VERSION, GEMSPEC.version.to_s.sub(".pre.", "-")
    assert_equal "tungo-sdk", GEMSPEC.name
    refute_empty Tungo::CONTRACT_VERSION
  end

  def test_both_entry_points_load_without_warnings
    %w[tungo tungo-sdk].each do |entry|
      assert_equal Tungo::VERSION, ruby("-Ilib", "-e", "require #{entry.inspect}; print Tungo::VERSION")
    end
  end

  def test_declared_dependencies
    assert_equal %w[base64 bigdecimal], GEMSPEC.runtime_dependencies.map(&:name).sort
    assert_equal Gem::Requirement.new(">= 3.2.0"), GEMSPEC.required_ruby_version
  end

  def test_no_undeclared_standard_library_is_required
    sources = Dir[File.join(ROOT, "lib/**/*.rb")].to_h { |file| [file, File.read(file)] }
    required = sources.values.flat_map { |source| source.scan(/^\s*require "([^"]+)"/) }.flatten.uniq.sort

    assert_equal %w[base64 bigdecimal date json net/http openssl pathname securerandom time uri], required
    sources.each { |file, source| refute_match(/\bCGI\b/, source, file) }
  end

  def test_every_source_file_is_frozen_string_literal
    Dir[File.join(ROOT, "{lib,test,examples}/**/*.rb"), File.join(ROOT, "*.gemspec")].each do |file|
      assert_equal "# frozen_string_literal: true\n", File.open(file, &:gets), file
    end
  end

  def test_packaged_files
    files = GEMSPEC.files

    assert_includes files, "lib/tungo.rb"
    assert_includes files, "lib/tungo-sdk.rb"
    assert_includes files, "sig/tungo/runtime.rbs"
    assert_includes files, "README.md"
    assert_includes files, "LICENSE"
    assert(files.none? { |file| file.start_with?("test/", "examples/", ".github/") })
  end

  def test_the_production_host_is_the_only_one
    retired = %w[api tungo ai].join(".")
    Dir[File.join(ROOT, "{lib,sig,examples}/**/*"), File.join(ROOT, "README.md")].each do |file|
      next unless File.file?(file)

      refute_includes File.read(file), retired, file
    end
  end

  def test_examples_run_against_the_mock
    server.respond { |request| demo_response(request) }
    env = { "TUNGO_API_KEY" => "tg_test_key", "TUNGO_BASE_URL" => server.base_url, "TUNGO_COMPANY_ID" => "co_1",
            "TUNGO_WEBHOOK_SECRET" => "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" }
    examples = Dir[File.join(ROOT, "examples/*.rb")]

    assert_operator examples.size, :>=, 4
    examples.each do |file|
      output, status = Open3.capture2e(env, RbConfig.ruby, "-w", "-Ilib", file, chdir: ROOT)

      assert_predicate status, :success?, "#{file}:\n#{output}"
      refute_match(/warning:/, output, file)
      refute_empty output, file
    end
  end
end
