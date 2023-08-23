# frozen_string_literal: true

require 'prawn'
exit if defined?(Aibika)
Prawn::Document.generate('prawn_sample.pdf') do
  text 'Hello, World!'
  font.instance_eval { find_font('Helvetica.afm') } or raise
end
File.unlink('prawn_sample.pdf')
