# frozen_string_literal: true

Dir.chdir File.dirname(__FILE__)
raise unless File.exist? 'assets/resource1.txt'
raise unless File.read('assets/resource1.txt') == "resource1\n"
raise unless File.exist? 'assets/subdir/resource2.txt'
raise unless File.read('assets/subdir/resource2.txt') == "resource2\n"
