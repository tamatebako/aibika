# frozen_string_literal: true

require 'rubygems'
gem 'sys-proctable'
require 'sys/proctable'
require 'time'
include Sys

# Everything
ProcTable.ps do |p|
  puts "#{p.pid}    #{p.comm}"
end
