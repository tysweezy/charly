require "colorize"

require "./ast.cr"
require "./lexer.cr"

require "../exceptions.cr"
require "../interpreter/session.cr"

module Charly::Parser

  # Parses a list of tokens into a program
  class Parser
    include CharlyExceptions
    include AST

    property file : VirtualFile
    property session : Session

    property tokens : Array(Token)
    property token : Token
    property pos : Int32

    property tree : Program

    # Create a new parser from a virtualfile
    def initialize(@file, @session)
      @pos = 0
      @tokens = Lexer.new(file).all_tokens.select do |token|
        token.type != TokenType::Whitespace &&
        token.type != TokenType::Newline &&
        token.type != TokenType::Comment &&
        token.type != TokenType::EOF
      end
      @token = Token.new

      # Print tokens
      if @session.flags.includes?("tokens") && @session.file == @file
        @tokens.each do |token|
          puts token
        end
      end

      # Initialize the tree
      @tree = Program.new
    end

    # Begin parsing
    def parse

      # If no interesting tokens were found in this file, don't try to parse it
      if @tokens.size == 0
        @tree << Block.new([] of ASTNode)
      else
        @token = @tokens[0]
        @tree << parse_block_body(false)
      end

      # Print the tree if the ast flag was set
      if @session.flags.includes?("ast") && @session.file == @file
        puts @tree
      end

      # Return the tree
      return @tree
    end

    def has_next?
      @pos + 1 < @tokens.size
    end

    # Returns the next token
    def peek?
      if @pos + 1 >= @tokens.size
        return unexpected_eof
      end

      @tokens[@pos + 1]
    end

    # Advances the pointer to the next token
    def advance
      if @pos + 1 >= @tokens.size
        return unexpected_eof
      end

      @pos += 1
      @token = @tokens[@pos]
    end

    # Throws a SyntaxError
    def unexpected_token
      raise SyntaxError.new(@token.location, "Unexpected token: #{@token.type}")
    end

    def unexpected_eof
      new_token = Token.new(TokenType::EOF)
      new_token.location = @token.location.dup
      new_token.location.column += new_token.location.length - 1
      new_token.location.length = 0

      @token = new_token
      @pos += 1

      return new_token
    end

    # Tries all productions
    # Catches SyntaxErrors
    # The first production that succeeds will be returned
    # If no production succeeded this will raise the last
    # SyntaxError thrown by the productions
    def try(*prods : Proc(ASTNode | Bool))
      start_pos = @pos
      result = nil

      prods.each_with_index do |prod, index|
        begin
          result = prod.call
          break
        rescue e : SyntaxError
          if index == prods.size - 1
            raise e
          end

          @pos = start_pos
          @token = @tokens[@pos]
        end
      end

      if result.is_a?(Nil)
        raise "fail"
      end

      return result
    end

    def optional(*prods)
      begin
        return try(*prods)
      rescue e : SyntaxError
        return Empty.new
      end
    end

    def assert_token(type : TokenType)
      unless @token.type == type
        unexpected_token
      end

      true
    end

    def assert_token(type : TokenType)
      unless @token.type == type
        unexpected_token
      end

      yield
    end

    def assert_token(type : TokenType, value : String)
      unless @token.type == type && @token.value == value
        unexpected_token
      end

      true
    end

    def assert_token(type : TokenType, value : String)
      unless @token.type == type && @token.value == value
        unexpected_token
      end

      yield
    end

    def if_token(type : TokenType)
      @token.type == type
    end

    def if_token(type : TokenType)
      yield if @token.type == type
    end

    def if_token(type : TokenType, value : String)
      @token.type == type && @token.value == value
    end

    def if_token(type : TokenType, value : String)
      yield if @token.type == type && @token.value == value
    end

    # Parses a block body surrounded by Curly Braces
    def parse_block
      case @token.type
      when TokenType::LeftCurly
        advance
        body = parse_block_body

        case @token.type
        when TokenType::RightCurly
          advance
          return body
        else
          unexpected_token
        end
      else
        unexpected_token
      end
    end

    # Parses the body of a block
    def parse_block_body(stop_on_curly = true)
      exps = [] of ASTNode

      if stop_on_curly
        until @token.type == TokenType::RightCurly
          exps << parse_statement
        end
      else
        until @token.type == TokenType::EOF
          exps << parse_statement
        end
      end

      return Block.new(exps)
    end

    def parse_statement
      case @token.type
      when TokenType::Keyword
        case @token.value
        when "let"
          case advance.type
          when TokenType::Identifier
            identifier = IdentifierLiteral.new(@token.value)

            case advance.type
            when TokenType::Semicolon
              advance
              return VariableDeclaration.new(identifier)
            when TokenType::Assignment
              advance
              value = parse_expression

              if_token TokenType::Semicolon do
                advance
              end

              return VariableInitialisation.new(identifier, value)
            else
              return VariableDeclaration.new(identifier)
            end
          else
            unexpected_token
          end
        when "const"
          case advance.type
          when TokenType::Identifier
            identifier = IdentifierLiteral.new(@token.value)

            case advance.type
            when TokenType::Assignment
              advance
              value = parse_expression

              if_token TokenType::Semicolon do
                advance
              end

              return ConstantInitialisation.new(identifier, value)
            else
              unexpected_token
            end
          else
            unexpected_token
          end
        when "if"
          return parse_if_statement
        when "while"
          return parse_while_statement
        when "try"
          return parse_try_statement
        when "return"
          advance
          node = ReturnStatement.new(optional ->{ parse_expression })

          if_token TokenType::Semicolon do
            advance
          end

          return node
        when "break"
          advance
          node = BreakStatement.new
        when "throw"
          advance
          node = ThrowStatement.new(optional ->{ parse_expression })

          if_token TokenType::Semicolon do
            advance
          end

          return node
        end
      else
        begin
          expression = parse_expression

          if_token TokenType::Semicolon do
            advance
          end

          return expression
        rescue e : SyntaxError
          unexpected_token
        end
      end

      unexpected_token
    end

    def parse_if_statement

      unexpected_token unless if_token TokenType::Keyword, "if"

      case advance.type
      when TokenType::LeftParen
        advance

        test = parse_expression

        assert_token TokenType::RightParen do
          advance
        end
      else
        test = parse_expression
      end

      consequent = parse_block

      alternate = Empty.new
      if_token TokenType::Keyword, "else" do
        advance

        case @token.type
        when TokenType::Keyword
          case @token.value
          when "if"
            alternate = parse_if_statement
          else
            unexpected_token
          end
        else
          alternate = parse_block
        end
      end

      return IfStatement.new(test, consequent, alternate)
    end

    def parse_while_statement

      unexpected_token unless if_token TokenType::Keyword, "while"

      case advance.type
      when TokenType::LeftParen
        advance
        test = parse_expression

        case @token.type
        when TokenType::RightParen
          advance
        else
          unexpected_token
        end
      else
        test = parse_expression
      end

      consequent = parse_block
      return WhileStatement.new(test, consequent)
    end

    def parse_try_statement

      unexpected_token unless if_token TokenType::Keyword, "try"

      try_block = Empty.new
      exception_name = IdentifierLiteral.new("e")
      catch_block = Empty.new

      advance
      try_block = parse_block

      assert_token TokenType::Keyword, "catch" do
        advance
      end

      case @token.type
      when TokenType::LeftParen
        advance

        assert_token TokenType::Identifier do
          exception_name = IdentifierLiteral.new(@token.value)
          advance

          assert_token TokenType::RightParen do
            advance
          end
        end
      else
        assert_token TokenType::Identifier do
          exception_name = IdentifierLiteral.new(@token.value)
          advance
        end
      end

      catch_block = parse_block

      return TryCatchStatement.new(try_block, exception_name, catch_block)
    end

    def parse_expression
      return parse_literal
    end

    def parse_literal
      case @token.type
      when TokenType::Identifier
        node = IdentifierLiteral.new(@token.value)
        advance
      when TokenType::Numeric
        node = NumericLiteral.new(@token.value.to_f64)
        advance
      when TokenType::String
        node = StringLiteral.new(@token.value)
        advance
      when TokenType::Boolean
        node = BooleanLiteral.new(@token.value == "true")
        advance
      when TokenType::Null
        node = NullLiteral.new
        advance
      when TokenType::NAN
        node = NANLiteral.new
        advance
      when TokenType::LeftBracket
        node = parse_array_literal
      when TokenType::LeftCurly
        node = parse_container_literal
      when TokenType::Keyword
        case @token.value
        when "func"
          node = parse_func_literal
        when "class"
          node = parse_class_literal
        else
          unexpected_token
        end
      else
        unexpected_token
      end

      return node
    end

    def parse_expression_list(end_token : TokenType)
      exps = [] of ASTNode

      should_read = @token.type != end_token
      while should_read
        should_read = false

        exps << parse_expression

        if @token.type == TokenType::Comma
          should_read = true
          advance
        end
      end

      return ExpressionList.new(exps)
    end

    def parse_array_literal
      assert_token TokenType::LeftBracket do
        advance
      end

      exps = parse_expression_list(TokenType::RightBracket)

      assert_token TokenType::RightBracket do
        advance
      end

      return ArrayLiteral.new(exps.children)
    end

    def parse_container_literal
      return ContainerLiteral.new(Block.new([] of ASTNode))
    end

    def parse_func_literal
      return FunctionLiteral.new(IdentifierList.new([] of ASTNode), Block.new([] of ASTNode))
    end

    def parse_class_literal
      return ClassLiteral.new(Block.new([] of ASTNode))
    end
  end
end
