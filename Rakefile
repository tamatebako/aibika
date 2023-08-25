# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rubocop/rake_task'
require 'minitest/test_task'

RuboCop::RakeTask.new
Minitest::TestTask.create

task default: %i[test]

desc 'Build Aibika stubs'
task :build_stub do
  system('mingw32-make -C src')
  cp 'src/stub.exe', 'share/aibika/stub.exe'
  cp 'src/stubw.exe', 'share/aibika/stubw.exe'
  cp 'src/edicon.exe', 'share/aibika/edicon.exe'
end

file 'share/aibika/stub.exe' => :build_stub
file 'share/aibika/stubw.exe' => :build_stub
file 'share/aibika/edicon.exe' => :build_stub

task test: :build_stub
task build: :build_stub

task :clean do
  rm_f Dir['{bin,samples}/*.exe']
  rm_f Dir['share/aibika/{stub,stubw,edicon}.exe']
  system('mingw32-make -C src clean')
end
