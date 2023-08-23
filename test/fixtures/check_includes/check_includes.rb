require 'rbconfig'
exit if defined?(Aibika)
if Dir[File.join(RbConfig::CONFIG["exec_prefix"], "include", "**", "*.h")].size != ARGV[0].to_i
  raise "Failed"
end
