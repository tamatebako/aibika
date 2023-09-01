# frozen_string_literal: true

require 'cgi'
File.write('output.txt', CGI.escapeHTML('3 < 5'))
