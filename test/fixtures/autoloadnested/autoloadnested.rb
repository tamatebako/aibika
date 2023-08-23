# frozen_string_literal: true

$LOAD_PATH.unshift File.dirname(__FILE__)
module Bar
  autoload :Foo, 'foo'
end
Bar::Foo if __FILE__ == $PROGRAM_NAME
