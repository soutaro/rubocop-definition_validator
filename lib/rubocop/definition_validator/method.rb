require 'ripper'

module Rubocop::DefinitionValidator
  # a method
  class Method
    class InvalidAST < ArgumentError; end

    attr_reader :name

    # @param [String] definition
    #
    # Definition Example:
    #   def f(a, b, c, m = 1, n = 1, *rest, x, y, z, k: 1, **kwrest, &blk)
    #
    # AST Example:
    #   [:program,
    #    [[:def,
    #      [:@ident, "f", [1, 4]],
    #      [:paren,
    #       [:params,
    #        [[:@ident, "a", [1, 6]], [:@ident, "b", [1, 9]], [:@ident, "c", [1, 12]]],
    #        [[[:@ident, "m", [1, 15]], [:@int, "1", [1, 19]]], [[:@ident, "n", [1, 22]], [:@int, "1", [1, 26]]]],
    #        [:rest_param, [:@ident, "rest", [1, 30]]],
    #        [[:@ident, "x", [1, 36]], [:@ident, "y", [1, 39]], [:@ident, "z", [1, 42]]],
    #        [[[:@label, "k:", [1, 45]], [:@int, "1", [1, 48]]]],
    #        [:@ident, "kwrest", [1, 53]],
    #        [:blockarg, [:@ident, "blk", [1, 62]]]]],
    #      [:bodystmt, [[:void_stmt]], nil, nil, nil]]]]
    #
    def initialize(definition)
      code = "#{definition}; end"
      ast = Ripper.sexp(code)

      begin
        params = ast[1][0][2]
        name = ast[1][0][1][1]
      rescue NoMethodError => ex
        raise InvalidAST, "Can't parse AST. \nCode: #{code}\nError: #{ex}"
      end

      if params[0] == :paren
        params = params[1]
      end

      @params = params[1..-1]
      @name = name
    end

    # @param [Array<RuboCop::Node>] args
    # @return [Boolean] callable
    # @return [Object] cause
    def callable?(name, args)
      return false, :method_name unless name == @name

      args = args.dup

      # 通常の引数分shift
      normal_params_size = (normal_params || []).size
      received_normal_params_size = args.shift(normal_params_size).size
      unless received_normal_params_size == normal_params_size
        return false, :not_enough_norml_arguments, received_normal_params_size, normal_params_size
        
      end

      if has_required_keyword_params?
        decide_with_required_keyword_params(args)
      elsif has_keyword_params?
        decide_with_keyword_params(args)
      else
        decide_rest_args(args)
      end
    end


    %i[
      normal_params
      default_value_params
      rest_params
      normal_params_after_rest
      keyword_params
      keyword_rest_params
    ].each.with_index do |name, idx|
      eval <<-CODE
  def #{name}
    @params[#{idx}]
  end
      CODE
    end


    private

    # decide default_value_params, rest_params, normal_params_after_rest
    # @param [Array<RuboCop::Node>] args
    # @return [Boolean]
    def decide_rest_args(args)
      normal_params_after_rest_size = (normal_params_after_rest || []).size
      given_normal_params_after_rest_size = args.pop(normal_params_after_rest_size).size
      unless given_normal_params_after_rest_size == normal_params_after_rest_size
        return false, :not_enough_normal_after_rest_arguments, given_normal_params_after_rest_size, normal_params_after_rest_size
      end

      # rest引数があれば全て呑み込むためtrue
      return true if rest_params
      # デフォルト値付き引数の数だけは呑み込める
      if default_value_params
        return true if args.size <= default_value_params.size
        # XXX: optimize message.
        return false, :too_many_arguments
      end
      return true if args.empty?
      return false, :too_many_arguments
    end

    def decide_with_required_keyword_params(args)
      kwparam = args.pop(1)
      usable, *reason = usable_as_keyword_param?(kwparam[0])
      return false, *reason unless usable

      return decide_rest_args(args)
    end

    def decide_with_keyword_params(args)
      ok, *_ = decide_rest_args(args.dup)
      return true if ok

      return decide_with_required_keyword_params(args)
    end


    def has_keyword_params?
      !!((keyword_params && !keyword_params.empty?) ||
        keyword_rest_params)
    end

    def has_required_keyword_params?
      (keyword_params && !keyword_params.empty?) &&
        keyword_params.any?{|p| p[1] == false}
    end


    # @param [RuboCop::Node] arg
    def usable_as_keyword_param?(arg)
      # should be hash
      return false, :kwparam_required unless arg
      return false, :kwparam_should_be_hash, arg.loc.expression.source unless arg.hash_type? || !arg.literal?

      # should have specified keyword
      return true unless arg.hash_type?

      required_keyword_names = keyword_params
        .select{|x| x[1] == false}
        .map{|x| x[0][1]}
        .map{|x| x.chop.to_sym}

      received_keyword_names = arg
        .children
        .map(&:children)
        .map{|x| x.first}
        .map(&:children)
        .map{|x| x.first}

      not_fould_requireds = required_keyword_names.select do |name|
        not received_keyword_names.include?(name)
      end
      unless not_fould_requireds.empty?
        return false, :kwparam_not_found, not_fould_requireds.join(', ')
      end

      return true if keyword_rest_params

      allowed_keyword_names = keyword_params
        .map{|x| x[0][1]}
        .map{|x| x.chop.to_sym}

      unexpected_keywords =  received_keyword_names.select do |name|
        not allowed_keyword_names.include?(name)
      end
      unless unexpected_keywords.empty?
        return false, :unexpected_kwparam, unexpected_keywords
      end
      return true
    end
  end
end
