# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |task|
  task.libs << "test" << "lib"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

RuboCop::RakeTask.new(:rubocop)

desc "Validate the RBS signatures"
task :rbs do
  libraries = %w[bigdecimal date json net-http pathname uri].flat_map { |name| ["-r", name] }
  sh "rbs", *libraries, "-I", "sig", "validate"
end

desc "Check the syntax of the examples"
task :examples do
  Dir["examples/*.rb"].each { |file| sh "ruby", "-wc", file }
end

task default: %i[test rubocop rbs examples]
