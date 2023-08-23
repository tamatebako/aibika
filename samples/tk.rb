# frozen_string_literal: true

require 'tk'
root = TkRoot.new { title 'Hello, World!' }
TkLabel.new(root) do
  text 'Hello, World!'
  pack do
    padx 15
    pady 15
    side 'left'
  end
end
Tk.mainloop
