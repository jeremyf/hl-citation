# coding: utf-8
require "hl/citation/version"
require 'namae'
module Hl
  module Citation
    class Error < StandardError; end

    class Name
      def initialize(string)
        @name = Namae::Name.parse(string)
      end

      def to_s
        [@name.send(:initials_of, @name.send(:given_part), dots: true), @name.send(:family_part)].join(" ")
      end
    end

    module Query
      require 'sparql/client'
      class Client
        def initialize
          @client =  SPARQL::Client.new(self.class.endpoint, method: :get, headers: { 'User-Agent' => self.class.user_agent })
        end

        def self.endpoint
          @endpoint ||= "https://query.wikidata.org/sparql".freeze
        end

        def self.user_agent
          @user_agent ||= "HL-Citation/0.0.1 (https://library.nd.edu ;jfriesen@nd.edu) sparql.gem/3.1.3".freeze
        end

        def query(spql)
          @client.query(spql)
        end
      end

      module WithClient
        def client
          @client ||= Client.new
        end

        def query(cached: true)
          if cached
            with_cache { client.query(to_sparql) }
          else
            client.query(to_sparql)
          end
        end

        require 'json'
        def with_cache
          cache_prefix = self.class.to_s.gsub(/\W+/,"-").downcase
          file_name = File.join(File.expand_path("../../tmp", __dir__), "#{cache_prefix}-#{cache_key}.obj")
          return Marshal.load(File.read(file_name)) if File.exist?(file_name)

          results = yield
          File.open(file_name, "w+") { |f| f.puts Marshal.dump(results) }
          return results
        end
      end

      class Publication
        include WithClient
        def sparql_template
          spq = <<'SPARQL'.chop


SELECT ?description ?value ?valueUrl
WHERE {
  BIND(wd:%<publication_id>s AS ?work)
  {
    BIND(1 AS ?order)
    BIND("Title" AS ?description)
    ?work wdt:P1476 ?value .
  }
  UNION
  {
    SELECT
      (2 AS ?order)
      ("Authors" AS ?description)
      (GROUP_CONCAT(?value_; separator=", ") AS ?value)
      (CONCAT("../authors/", GROUP_CONCAT(?q; separator=",")) AS ?valueUrl)
    {
      BIND(1 AS ?dummy)
      wd:%<publication_id>s wdt:P50 ?iri .
      BIND(SUBSTR(STR(?iri), 32) AS ?q)
      ?iri rdfs:label ?value_string .
      FILTER (LANG(?value_string) = 'en')
      BIND(COALESCE(?value_string, ?q) AS ?value_)
    }
    GROUP BY ?dummy
  }
  UNION
  {
    SELECT
      (3 AS ?order)
      ("Author Names" AS ?description)
      (GROUP_CONCAT(?value_; separator="\t") AS ?value)
      (CONCAT("../authors/", GROUP_CONCAT(?q; separator=",")) AS ?valueUrl)
    {
      BIND(1 AS ?dummy)
      wd:%<publication_id>s wdt:P2093 ?iri .
      BIND(SUBSTR(STR(?iri), 32) AS ?q)
      ?iri rdfs:label ?value_string .
      FILTER (LANG(?value_string) = 'en')
      BIND(COALESCE(?value_string, ?q) AS ?value_)
    }
    GROUP BY ?dummy
  }
  UNION
  {
    BIND(4 AS ?order)
    BIND("Published in" AS ?description)
    ?work wdt:P1433 ?iri .
    BIND(SUBSTR(STR(?iri), 32) AS ?q)
    ?iri rdfs:label ?value_string .
    FILTER (LANG(?value_string) = 'en')
    BIND(COALESCE(?value_string, ?q) AS ?value)
    BIND(CONCAT("../venue/", ?q) AS ?valueUrl)
  }
  UNION
  {
    BIND(4 AS ?order)
    BIND("Series" AS ?description)
    ?work wdt:P179 ?iri .
    BIND(SUBSTR(STR(?iri), 32) AS ?q)
    ?iri rdfs:label ?value_string .
    FILTER (LANG(?value_string) = 'en')
    BIND(COALESCE(?value_string, ?q) AS ?value)
    BIND(CONCAT("../series/", ?q) AS ?valueUrl)
  }
  UNION
  {
    BIND(6 AS ?order)
    BIND("Publication date" AS ?description)
    ?work p:P577 / psv:P577 ?publication_date_value .
    ?publication_date_value wikibase:timePrecision ?time_precision ;
                            wikibase:timeValue ?publication_date .
    BIND(IF(?time_precision = 9, YEAR(?publication_date), xsd:date(?publication_date)) AS ?value)
  }
  UNION
  {
    SELECT
      (7 AS ?order)
      ("Topics" AS ?description)
      (GROUP_CONCAT(?value_; separator=", ") AS ?value)
      (CONCAT("../topics/", GROUP_CONCAT(?q; separator=",")) AS ?valueUrl)
    {
      BIND(1 AS ?dummy)
      wd:%<publication_id>s wdt:P921 ?iri .
      BIND(SUBSTR(STR(?iri), 32) AS ?q)
      ?iri rdfs:label ?value_string .
      FILTER (LANG(?value_string) = 'en')
      BIND(COALESCE(?value_string, ?q) AS ?value_)
    }
    GROUP BY ?dummy
  }
  UNION
  {
    BIND(10 AS ?order)
    BIND("DOI" AS ?description)
    ?work wdt:P356 ?valueUrl_ .
    BIND(CONCAT("https://dx.doi.org/", ENCODE_FOR_URI(?valueUrl_)) AS ?valueUrl)
    BIND(CONCAT(?valueUrl_, " ->") AS ?value)
  }
  UNION
  {
    BIND(11 AS ?order)
    BIND("Homepage" AS ?description)
    ?work wdt:P856 ?valueUrl .
    BIND(STR(?valueUrl) AS ?value)
  }
}
ORDER BY ?order


SPARQL
        end

        def initialize(publication_id:)
          @publication_id = publication_id
        end

        def cache_key
          @publication_id
        end

        def to_sparql
          sprintf(sparql_template, { publication_id: @publication_id })
        end

      end
      class AuthorList
        include WithClient
        def sparql_template
          spq = <<'SPARQL'.chop
# List of authors for a work
SELECT
  # Author order
  ?order

  ?academic_age

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
  OPTIONAL {
    SELECT ?author_ (MAX(?academic_age_) AS ?academic_age) {
      wd:%<publication_id>s wdt:P50 ?author_ ;
                   wdt:P577 ?publication_date .
      ?author_ ^wdt:P50 / wdt:P577 ?other_publication_date .
      BIND(YEAR(?publication_date) - YEAR(?other_publication_date) AS ?academic_age_)
    }
    GROUP BY ?author_
  }
}
ORDER BY ?order
SPARQL
        end
        def initialize(publication_id:)
          @publication_id = publication_id
        end

        def cache_key
          @publication_id
        end

        def to_sparql
          sprintf(sparql_template, { publication_id: @publication_id })
        end
      end

      class PublicationsForAuthor
        include WithClient
        def sparql_template
          sp = <<'SPARQL'.chop

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
        def initialize(author_id:)
          @author_id = author_id
        end
        def to_sparql
          sprintf(sparql_template, { author_id: @author_id })
        end

        def cache_key
          @author_id
        end
      end
    end
  end
end


# author = Hl::Citation::Query::AuthorList.new(publication_id: "Q61360184")
# publication = Hl::Citation::Query::Publication.new(publication_id: "Q61360184")
Hl::Citation::Query::PublicationsForAuthor.new(author_id: "Q101570745").query.each do |row|

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