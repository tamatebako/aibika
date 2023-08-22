require "bundler/gem_tasks"
require "rubocop/rake_task"
require "minitest/test_task"

RuboCop::RakeTask.new
task default: %i[rubocop]

Minitest::TestTask.create

task :build_stub do
  sh "mingw32-make -C src"
  cp "src/stub.exe", "share/ocra/stub.exe"
  cp "src/stubw.exe", "share/ocra/stubw.exe"
  cp "src/edicon.exe", "share/ocra/edicon.exe"
end

file "share/ocra/stub.exe" => :build_stub
file "share/ocra/stubw.exe" => :build_stub
file "share/ocra/edicon.exe" => :build_stub

task :test => :build_stub

task :clean do
  rm_f Dir["{bin,samples}/*.exe"]
  rm_f Dir["share/ocra/{stub,stubw,edicon}.exe"]
  sh "mingw32-make -C src clean"
end
