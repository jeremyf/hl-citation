# coding: utf-8
require "hl/citation/version"

module Hl
  module Citation
    class Error < StandardError; end

    module Query
      class Publication
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

        def to_sparql
          sprintf(sparql_template, { publication_id: @publication_id })
        end

      end
      class AuthorList
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
        def to_sparql
          sprintf(sparql_template, { publication_id: @publication_id })
        end
      end

      class PublicationsForAuthor
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
      end
    end
  end
end


author = Hl::Citation::Query::AuthorList.new(publication_id: "Q61360184")
publication = Hl::Citation::Query::Publication.new(publication_id: "Q61360184")
publications_for_author = Hl::Citation::Query::PublicationsForAuthor.new(author_id: "Q101570745")

#gem install sparql
#http://www.rubydoc.info/github/ruby-rdf/sparql/frames

require 'sparql/client'

endpoint = "https://query.wikidata.org/sparql"


USER_AGENT = "HL-Citation/0.0.1 (https://library.nd.edu ;jfriesen@nd.edu) sparql.gem/3.1.3".freeze

client = SPARQL::Client.new(endpoint, method: :get, headers: { 'User-Agent' => USER_AGENT })

# author_results = client.query(author.to_sparql)
# File.open("/Users/jfriesen/git/hl-citation/tmp/author.obj", "w+") do |f|
#   f.puts Marshal.dump(author_results)
# end

# publication_results = client.query(publication.to_sparql)
# File.open("/Users/jfriesen/git/hl-citation/tmp/publication.obj", "w+") do |f|
#   f.puts Marshal.dump(publication_results)
# end

publications_for_author_results = client.query(publications_for_author.to_sparql)
File.open("/Users/jfriesen/git/hl-citation/tmp/publications_for_author.obj", "w+") do |f|
  f.puts Marshal.dump(publications_for_author_results)
end

# puts "Number of rows: #{rows.size}"
# for row in rows
#   for key,val in row do
#     # print "#{key.to_s.ljust(10)}: #{val}\t"
#     print "#{key}: #{val}\t"
#   end
#   print "\n"
# end
