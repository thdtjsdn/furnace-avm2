module Furnace::AVM2::Tokens
  class ScriptToken < Furnace::Code::NonterminalToken
    include TokenWithTraits

    def initialize(origin, options={})
      options = options.merge(environment: :script, global_context: origin)

      super(origin, [
        *transform_traits(origin, options.merge(static: false)),
        Furnace::AVM2::Decompiler.new(origin.initializer_body,
              options.merge(global_code: true)).decompile
      ], options)
    end
  end
end