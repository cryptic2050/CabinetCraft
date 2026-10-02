# frozen_string_literal: true

module CabinetCraft
  module Templates
    # A small, SAFE arithmetic expression language for cabinet templates. It is parsed by hand and evaluated over a
    # variable hash: no Ruby eval, no method calls, no strings, no loops. Everything is a Float.
    #
    #   numbers   12  3.5          variables  W  shelf_count  side_t
    #   operators + - * / %  (unary -)   comparison < <= > >= == !=   logic && || !   (true = 1, false = 0)
    #   functions min max abs floor ceil round sqrt clamp  if(cond, a, b)  (if evaluates only the chosen branch)
    #
    # Limits keep a hostile template from hanging the plugin: 400 characters, 200 nodes, nesting depth 40.
    module Expression
      class ParseError < StandardError; end
      class EvalError < StandardError; end

      MAX_LENGTH = 400
      MAX_NODES = 200
      MAX_DEPTH = 40
      FUNCTIONS = { 'min' => 1..8, 'max' => 1..8, 'abs' => 1..1, 'floor' => 1..1, 'ceil' => 1..1, 'round' => 1..2, 'sqrt' => 1..1,
                    'clamp' => 3..3, 'if' => 3..3 }.freeze
      TOKEN = /\s*(?:(\d+\.?\d*|\.\d+)|([A-Za-z_][A-Za-z0-9_]*)|(&&|\|\||<=|>=|==|!=|[-+*\/%(),<>!]))/.freeze

      Node = Struct.new(:type, :a, :b, :c)

      module_function

      # Returns an AST (Node). Raises ParseError with a readable message.
      def parse(text)
        src = text.to_s
        raise ParseError, 'Expression is empty' if src.strip.empty?
        raise ParseError, "Expression is longer than #{MAX_LENGTH} characters" if src.size > MAX_LENGTH

        tokens = tokenize(src)
        parser = Parser.new(tokens)
        ast = parser.parse_expression(0)
        raise ParseError, "Unexpected '#{parser.peek[1]}'" unless parser.peek.nil?
        raise ParseError, "Expression is too complex (more than #{MAX_NODES} parts)" if count(ast) > MAX_NODES

        ast
      end

      def tokenize(src)
        out = []
        pos = 0
        while pos < src.size
          break if src[pos..].strip.empty?

          m = TOKEN.match(src, pos)
          raise ParseError, "Unexpected character '#{src[pos..].lstrip[0]}'" unless m && m.begin(0) == pos

          if m[1] then out << [:num, m[1].to_f]
          elsif m[2] then out << [:id, m[2]]
          else out << [:op, m[3]]
          end
          pos = m.end(0)
        end
        out
      end

      def count(node)
        return 0 unless node.is_a?(Node)

        1 + [node.a, node.b, node.c].sum { |x| x.is_a?(Array) ? x.sum { |y| count(y) } : count(x) }
      end

      # Names of variables an expression reads (function names excluded).
      def variables(node)
        return [] unless node.is_a?(Node)

        own = node.type == :var ? [node.a] : []
        own + [node.a, node.b, node.c].flat_map { |x| x.is_a?(Array) ? x.flat_map { |y| variables(y) } : variables(x) }
      end

      def evaluate(node, vars)
        case node.type
        when :num then node.a
        when :var
          vars.fetch(node.a) { raise EvalError, "Unknown variable '#{node.a}'" }
        when :neg then -evaluate(node.a, vars)
        when :not then evaluate(node.a, vars).zero? ? 1.0 : 0.0
        when :bin then binary(node, vars)
        when :call then call(node, vars)
        end.then { |v| check(v) }
      end

      def check(v)
        raise EvalError, 'Result is not a finite number' unless v.is_a?(Float) && v.finite?

        v
      end

      def binary(node, vars)
        op = node.a
        return (evaluate(node.b, vars).zero? ? 0.0 : (evaluate(node.c, vars).zero? ? 0.0 : 1.0)) if op == '&&'
        return (evaluate(node.b, vars).zero? ? (evaluate(node.c, vars).zero? ? 0.0 : 1.0) : 1.0) if op == '||'

        l = evaluate(node.b, vars)
        r = evaluate(node.c, vars)
        case op
        when '+' then l + r
        when '-' then l - r
        when '*' then l * r
        when '/' then r.zero? ? raise(EvalError, 'Division by zero') : l / r
        when '%' then r.zero? ? raise(EvalError, 'Division by zero') : l % r
        when '<' then l < r ? 1.0 : 0.0
        when '<=' then l <= r ? 1.0 : 0.0
        when '>' then l > r ? 1.0 : 0.0
        when '>=' then l >= r ? 1.0 : 0.0
        when '==' then (l - r).abs < 1e-9 ? 1.0 : 0.0
        when '!=' then (l - r).abs < 1e-9 ? 0.0 : 1.0
        end
      end

      def call(node, vars)
        name = node.a
        args = node.b
        return (evaluate(args[0], vars).zero? ? evaluate(args[2], vars) : evaluate(args[1], vars)) if name == 'if'

        v = args.map { |x| evaluate(x, vars) }
        case name
        when 'min' then v.min
        when 'max' then v.max
        when 'abs' then v[0].abs
        when 'floor' then v[0].floor.to_f
        when 'ceil' then v[0].ceil.to_f
        when 'round' then v.size == 2 ? v[0].round(v[1].to_i.clamp(0, 6)).to_f : v[0].round.to_f
        when 'sqrt' then v[0].negative? ? raise(EvalError, 'sqrt of a negative number') : Math.sqrt(v[0])
        when 'clamp' then [[v[0], v[1]].max, v[2]].min
        end
      end

      # Pratt parser over a token list.
      class Parser
        PREC = { '||' => 1, '&&' => 2, '==' => 3, '!=' => 3, '<' => 4, '<=' => 4, '>' => 4, '>=' => 4, '+' => 5, '-' => 5, '*' => 6, '/' => 6, '%' => 6 }.freeze

        def initialize(tokens)
          @t = tokens
          @i = 0
          @depth = 0
        end

        def peek
          @t[@i]
        end

        def take
          tok = @t[@i]
          @i += 1
          tok
        end

        def parse_expression(min_prec)
          @depth += 1
          raise ParseError, 'Expression is nested too deeply' if @depth > MAX_DEPTH

          left = parse_unary
          while (tok = peek) && tok[0] == :op && (prec = PREC[tok[1]]) && prec > min_prec
            op = take[1]
            right = parse_expression(prec)
            left = Node.new(:bin, op, left, right)
          end
          @depth -= 1
          left
        end

        def parse_unary
          tok = peek or raise ParseError, 'Expression ends unexpectedly'
          if tok == [:op, '-'] then take; return Node.new(:neg, parse_unary)
          elsif tok == [:op, '!'] then take; return Node.new(:not, parse_unary)
          end
          parse_primary
        end

        def parse_primary
          tok = take or raise ParseError, 'Expression ends unexpectedly'
          case tok[0]
          when :num then Node.new(:num, tok[1])
          when :id then identifier(tok[1])
          when :op
            raise ParseError, "Unexpected '#{tok[1]}'" unless tok[1] == '('

            inner = parse_expression(0)
            expect(')')
            inner
          end
        end

        def identifier(name)
          return Node.new(:var, name) unless peek == [:op, '(']

          raise ParseError, "Unknown function '#{name}'" unless FUNCTIONS.key?(name)

          take
          args = []
          unless peek == [:op, ')']
            loop do
              args << parse_expression(0)
              break unless peek == [:op, ',']

              take
            end
          end
          expect(')')
          raise ParseError, "#{name}() takes #{FUNCTIONS[name].min == FUNCTIONS[name].max ? FUNCTIONS[name].min : "#{FUNCTIONS[name].min}-#{FUNCTIONS[name].max}"} argument(s), got #{args.size}" unless FUNCTIONS[name].cover?(args.size)

          Node.new(:call, name, args)
        end

        def expect(op)
          tok = take
          raise ParseError, "Expected '#{op}'" unless tok == [:op, op]
        end
      end

      # Convenience: parse + evaluate.
      def run(text, vars = {})
        evaluate(parse(text), vars)
      end
    end
  end
end
