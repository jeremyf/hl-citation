# coding: utf-8
require "hl/citation/version"
require 'namae'
require 'json'
require 'sparql/client'

module Hl
  module Citation
    class Error < StandardError; end

    # @api private
    #
    # A quick and dirty method for generating citations based on query
    # results.
    #
    # @param author_id [String] The wikidata.org identifier for this author
    #
    # @return Hl::Citation
    def self.cited_publications_for(author_id: "Q101570745")
      Query::PublicationsForAuthor.new(author_id: author_id).query.each do |row|

        publication_id = row[:work].to_s.split("/").last
        title = row[:workLabel].to_s
        authors = []
        publication_date = Date.parse(row[:date].value).strftime("%Y") if row[:date]
        doi = row[:doi].value if row[:doi]
        venue = row[:venueLabel].value if row[:venueLabel]
        al = Hl::Citation::Query::AuthorList.new(publication_id: publication_id)
        al.query.each do |author_row|
          raw_author = author_row[:author]
          full_name = raw_author.to_s.sub("UNRESOLVED: ", "")
          authors << Hl::Citation::Name.new(full_name)
        end
        print authors.join(", ")
        print ". "
        print "#{publication_date}. " if publication_date
        print "#{title}. ".sub(/\.\. $/, ". ")
        print "#{venue}. " if venue
        print "#{doi}. " if doi
        puts "\n"
      end
      self
    end

    # A utility class for converting a name into a citation
    # appropriate name.  This is intended to provide an insulating
    # layer between a library that handles name generation.
    class Name
      def initialize(string)
        @name = Namae::Name.parse(string)
      end

      # Using the internals of the namae gem, convert the given name into a cited name.
      def to_s
        [@name.send(:initials_of, @name.send(:given_part), dots: true), @name.send(:family_part)].join(" ")
      end
    end

    # The Query module creates a namespace for querying Wikidata
    module Query

      # A configuration class that provides the #query method for running a Sparql query on wikidata.org
      class Client
        def initialize
          @client =  SPARQL::Client.new(self.class.endpoint, method: :get, headers: { 'User-Agent' => self.class.user_agent })
        end

        def self.endpoint
          @endpoint ||= "https://query.wikidata.org/sparql".freeze
        end

        # @see https://meta.wikimedia.org/wiki/User-Agent_policy for details on its construction
        def self.user_agent
          @user_agent ||= "HL-Citation/0.0.1 (https://library.nd.edu ; jfriesen@nd.edu) sparql.gem/3.1.3".freeze
        end

        def query(spql)
          @client.query(spql)
        end
      end

      # A mixin module for SparQL queries using the Client configuration.
      module WithClient

        # Run the Sparql query. By default cache the response to prevent excessive queries of Wikidata
        # @see to_sparql
        def query(cached: true)
          if cached
            with_cache { client.query(to_sparql) }
          else
            client.query(to_sparql)
          end
        end

        private

        def client
          @client ||= Client.new
        end

        def cache_prefix
          self.class.to_s.gsub(/\W+/,"-").downcase
        end

        def with_cache
          file_name = File.join(File.expand_path("../../tmp", __dir__), "#{cache_prefix}-#{cache_key}.obj")
          return Marshal.load(File.read(file_name)) if File.exist?(file_name)

          results = yield
          File.open(file_name, "w+") { |f| f.puts Marshal.dump(results) }
          return results
        end
      end

      # For a given `publication_id` generate the ordered author list for that publication.
      class AuthorList
        include WithClient
        def initialize(publication_id:)
          @publication_id = publication_id
        end

        def cache_key
          @publication_id
        end

        def to_sparql
          sprintf(sparql_template, { publication_id: @publication_id })
        end

        def sparql_template
          <<~'SPARQL'.chomp
            # List of authors for a work
            SELECT
              # Author order
              ?order

              # Author item and label
              ?author ?authorUrl ?authorDescription

              ?orcid
            WHERE {
              {
                wd:%<publication_id>s p:P50 ?author_statement .
                ?author_statement ps:P50 ?author_ .
                ?author_ rdfs:label ?author .
                FILTER (LANG(?author) = 'en')
                BIND(CONCAT("../author/", SUBSTR(STR(?author_), 32)) AS ?authorUrl)
                OPTIONAL {
                  ?author_statement pq:P1545 ?order_ .
                  BIND(xsd:integer(?order_) AS ?order)
                }
                OPTIONAL { ?author_ wdt:P496 ?orcid_ . }
                # Either show the ORCID iD or construct part of a URL to search on the ORCID homepage
                BIND(COALESCE(?orcid_, CONCAT("orcid-search/quick-search/?searchQuery=", ENCODE_FOR_URI(?author))) AS ?orcid)
                OPTIONAL {
                  ?author_ schema:description ?authorDescription .
                  FILTER (LANG(?authorDescription) = "en")
                }
              }
              UNION
              {
                wd:%<publication_id>s p:P2093 ?authorstring_statement .
                ?authorstring_statement ps:P2093 ?author_
                BIND(CONCAT("UNRESOLVED: ", ?author_) AS ?author)
                OPTIONAL {
                  ?authorstring_statement pq:P1545 ?order_ .
                  BIND(xsd:integer(?order_) AS ?order)
                }
                BIND(CONCAT("https://author-disambiguator.toolforge.org/names_oauth.php?doit=Look+for+author&name=", ENCODE_FOR_URI(?author_)) AS ?authorUrl)
              }
            }
            ORDER BY ?order
          SPARQL
        end
      end

      # For the given `author_id`, query fo all of the publications for that author.
      class PublicationsForAuthor
        include WithClient

        def initialize(author_id:)
          @author_id = author_id
        end

        def to_sparql
          sprintf(sparql_template, { author_id: @author_id })
        end

        def cache_key
          @author_id
        end

        # @note This is a modified version of the underlying Sparql query: https://scholia.toolforge.org/author/Q101570745
        def sparql_template
          <<~'SPARQL'.chomp
            #defaultView:Table
            SELECT
              (MIN(?dates) AS ?date)
              ?work ?workLabel
              (GROUP_CONCAT(DISTINCT ?type_label; separator=", ") AS ?type)
              (SAMPLE(?pages_) AS ?pages)
              ?venue ?venueLabel
              (GROUP_CONCAT(DISTINCT ?author_label; separator=", ") AS ?authors)
              (GROUP_CONCAT(DISTINCT ?doi_; separator=", ") AS ?doi)
              (CONCAT("../authors/", GROUP_CONCAT(DISTINCT SUBSTR(STR(?author), 32); separator=",")) AS ?authorsUrl)
            WHERE {
              ?work wdt:P50 wd:%<author_id>s .
              ?work wdt:P50 ?author .
              OPTIONAL {
                ?author rdfs:label ?author_label_ . FILTER (LANG(?author_label_) = 'en')
              }
              BIND(COALESCE(?author_label_, SUBSTR(STR(?author), 32)) AS ?author_label)
              OPTIONAL { ?work wdt:P31 ?type_ . ?type_ rdfs:label ?type_label . FILTER (LANG(?type_label) = 'en') }
              ?work wdt:P577 ?datetimes .
              BIND(xsd:date(?datetimes) AS ?dates)
              OPTIONAL { ?work wdt:P1104 ?pages_ }
              OPTIONAL { ?work wdt:P1433 ?venue }
              OPTIONAL { ?work wdt:P356 ?doi_ }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en,da,de,es,fr,jp,no,ru,sv,zh". }
            }
            GROUP BY ?work ?workLabel ?venue ?venueLabel
            ORDER BY DESC(?date)

          SPARQL
        end
      end
    end
  end
end
