# frozen_string_literal: true

require 'rbconfig'
exit if defined?(Aibika)
raise 'Failed' if Dir[File.join(RbConfig::CONFIG['exec_prefix'], 'include', '**', '*.h')].size != ARGV[0].to_i
