# frozen_string_literal: true

require 'active_record'
raise unless defined?(ActiveRecord)

puts ActiveRecord::VERSION::STRING
