module Furnace::AVM2::Tokens
  class ThrowToken < Furnace::Code::SurroundedToken

    def text_before
      "throw "
    end

    def text_after
      ";\n"
    end
  end
end