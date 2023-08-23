# frozen_string_literal: true

$LOAD_PATH.unshift File.dirname(__FILE__)
autoload :Foo, 'foo'
Foo if __FILE__ == $PROGRAM_NAME
