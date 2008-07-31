require 'sqlite3'
require 'sequel_core/adapters/shared/sqlite'

module Sequel
  # Top level module for holding all SQLite-related modules and classes
  # for Sequel.
  module SQLite
    # Database class for PostgreSQL databases used with Sequel and the
    # ruby-sqlite3 driver.
    class Database < Sequel::Database
      include ::Sequel::SQLite::DatabaseMethods
      
      set_adapter_scheme :sqlite
      
      # Mimic the file:// uri, by having 2 preceding slashes specify a relative
      # path, and 3 preceding slashes specify an absolute path.
      def self.uri_to_options(uri) # :nodoc:
        { :database => (uri.host.nil? && uri.path == '/') ? nil : "#{uri.host}#{uri.path}" }
      end
      
      private_class_method :uri_to_options
      
      # Connect to the database.  Since SQLite is a file based database,
      # the only options available are :database (to specify the database
      # name), and :timeout, to specify how long to wait for the database to
      # be available if it is locked (default is 5 seconds).
      def connect
        @opts[:database] = ':memory:' if @opts[:database].blank?
        db = ::SQLite3::Database.new(@opts[:database])
        db.busy_timeout(@opts.fetch(:timeout, 5000))
        db.type_translation = true
        # fix for timestamp translation
        db.translator.add_translator("timestamp") do |t, v|
          v =~ /^\d+$/ ? Time.at(v.to_i) : Time.parse(v) 
        end 
        db
      end
      
      # Return instance of Sequel::SQLite::Dataset with the given options.
      def dataset(opts = nil)
        SQLite::Dataset.new(self, opts)
      end
      
      # Disconnect all connections from the database.
      def disconnect
        @pool.disconnect {|c| c.close}
      end
      
      # Run the given SQL with the given arguments and return the number of changed rows.
      def execute(sql, *bind_arguments)
        _execute(sql, *bind_arguments){|conn| conn.execute_batch(sql, *bind_arguments); conn.changes}
      end
      
      # Run the given SQL with the given arguments and return the last inserted row id.
      def execute_insert(sql, *bind_arguments)
        _execute(sql, *bind_arguments){|conn| conn.execute(sql, *bind_arguments); conn.last_insert_row_id}
      end
      
      # Run the given SQL with the given arguments and yield each row.
      def execute_select(sql, *bind_arguments)
        _execute(sql, *bind_arguments){|conn| conn.query(sql, *bind_arguments){|r| yield r}}
      end
      
      # Run the given SQL with the given arguments and return the first value of the first row.
      def single_value(sql, *bind_arguments)
        _execute(sql, *bind_arguments){|conn| conn.get_first_value(sql, *bind_arguments)}
      end
      
      # Use the native driver transaction method if there isn't already a transaction
      # in progress on the connection, always yielding a connection inside a transaction
      # transaction.
      def transaction(&block)
        synchronize do |conn|
          return yield(conn) if conn.transaction_active?
          begin
            result = nil
            conn.transaction{result = yield(conn)}
            result
          rescue ::Exception => e
            raise (SQLite3::Exception === e ? Error.new(e.message) : e) unless Error::Rollback === e
          end
        end
      end
      
      private
      
      # Log the SQL and the arguments, and yield an available connection.  Rescue
      # any SQLite3::Exceptions and turn the into Error::InvalidStatements.
      def _execute(sql, *bind_arguments)
        begin
          log_info(sql, *bind_arguments)
          synchronize{|conn| yield conn}
        rescue SQLite3::Exception => e
          raise Error::InvalidStatement, "#{sql}\r\n#{e.message}"
        end
      end
      
      # SQLite does not need the pool to convert exceptions.
      # Also, force the max connections to 1 if a memory database is being
      # used, as otherwise each connection gets a separate database.
      def connection_pool_default_options
        o = super.merge(:pool_convert_exceptions=>false)
        # Default to only a single connection if a memory database is used,
        # because otherwise each connection will get a separate database
        o[:max_connections] = 1 if @opts[:database] == ':memory:' || @opts[:database].blank?
        o
      end
    end
    
    # Dataset class for SQLite datasets that use the ruby-sqlite3 driver.
    class Dataset < Sequel::Dataset
      include ::Sequel::SQLite::DatasetMethods
      
      EXPLAIN = 'EXPLAIN %s'.freeze
      PREPARED_ARG_PLACEHOLDER = ':'.freeze
      
      # SQLite already supports named bind arguments, so use directly.
      module ArgumentMapper
        include Sequel::Dataset::ArgumentMapper
        
        protected
        
        # Return a hash with the same values as the given hash,
        # but with the keys converted to strings.
        def map_to_prepared_args(hash)
          args = {}
          hash.each{|k,v| args[k.to_s] = v}
          args
        end
        
        private
        
        # Work around for the default prepared statement and argument
        # mapper code, which wants a hash that maps.  SQLite doesn't
        # need to do this, but still requires a value for the argument
        # in order for the substitution to work correctly.
        def prepared_args_hash
          true
        end
        
        # SQLite uses a : before the name of the argument for named
        # arguments.
        def prepared_arg(k)
          "#{prepared_arg_placeholder}#{k}".lit
        end
      end
      
      # SQLite prepared statement uses a new prepared statement each time
      # it is called, but it does use the bind arguments.
      module PreparedStatementMethods
        include ArgumentMapper
        
        private
        
        # Run execute_select on the database with the given SQL and the stored
        # bind arguments.
        def execute_select(sql, &block)
          @db.execute_select(sql, bind_arguments, &block)
        end
        
        # Run execute_insert on the database with the given SQL and the
        # stored bind arguments.
        def execute_insert(sql)
          @db.execute_insert(sql, bind_arguments)
        end
        
        # Run execute on the database with the given SQL and the stored bind
        # arguments.
        def execute(sql)
          @db.execute(sql, bind_arguments)
        end
        alias execute_dui execute
      end
      
      # Prepare an unnamed statement of the given type and call it with the
      # given values.
      def call(type, hash, values=nil, &block)
        prepare(type, nil, values).call(hash, &block)
      end
      
      # Return an array of strings specifying a query explanation for the
      # current dataset.
      def explain
        res = []
        @db.result_set(EXPLAIN % select_sql(opts), nil) {|r| res << r}
        res
      end
      
      # Yield a hash for each row in the dataset.
      def fetch_rows(sql)
        execute_select(sql) do |result|
          @columns = result.columns.map {|c| c.to_sym}
          column_count = @columns.size
          result.each do |values|
            row = {}
            column_count.times {|i| row[@columns[i]] = values[i]}
            yield row
          end
        end
      end
      
      # Use the ISO format for dates and timestamps, and quote strings
      # using the ::SQLite3::Database.quote method.
      def literal(v)
        case v
        when LiteralString
          v
        when String
          "'#{::SQLite3::Database.quote(v)}'"
        when Time
          literal(v.iso8601)
        when Date, DateTime
          literal(v.to_s)
        else
          super
        end
      end
      
      # Prepare the given type of query with the given name and store
      # it in the database.  Note that a new native prepared statement is
      # created on each call to this prepared statement.
      def prepare(type, name, values=nil)
        ps = to_prepared_statement(type, values)
        ps.extend(PreparedStatementMethods)
        db.prepared_statements[name] = ps if name
        ps
      end
      
      private
      
      # Run execute_select on the database with the given SQL.
      def execute_select(sql, &block)
        @db.execute_select(sql, &block)
      end
      
      # SQLite uses a : before the name of the argument as a placeholder.
      def prepared_arg_placeholder
        PREPARED_ARG_PLACEHOLDER
      end
    end
  end
end
