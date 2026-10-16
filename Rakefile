# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"] - ["test/live_test.rb"]
  t.warning = true
end

Rake::TestTask.new(:live) do |t|
  t.libs << "lib" << "test"
  t.test_files = ["test/live_test.rb"]
end

task default: :test
