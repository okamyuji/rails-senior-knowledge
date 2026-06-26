# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = '*_*/*_spec.rb'
end

desc 'README/.rb間で既知の技術的誤りパターンを横断検査する'
task :audit do
  ruby File.expand_path('scripts/audit_consistency.rb', __dir__)
end

task default: %i[audit spec]
