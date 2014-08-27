# coding: utf-8
require 'rexml/document'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # = Ogone DirectLink Gateway
    #
    # DirectLink is the API version of the Ogone Payment Platform. It allows server to server
    # communication between Ogone systems and your e-commerce website.
    #
    # This implementation follows the specification provided in the DirectLink integration
    # guide version 4.3.0 (25 April 2012), available here:
    # https://secure.ogone.com/ncol/Ogone_DirectLink_EN.pdf
    #
    # It also features aliases, which allow to store/unstore credit cards, as specified in
    # the Alias Manager Option guide version 3.2.1 (25 April 2012) available here:
    # https://secure.ogone.com/ncol/Ogone_Alias_EN.pdf
    #
    # It also implements the 3-D Secure feature, as specified in the DirectLink with
    # 3-D Secure guide version 3.0 (25 April 2012) available here:
    # https://secure.ogone.com/ncol/Ogone_DirectLink-3-D_EN.pdf
    #
    # It was last tested on Release 4.92 of Ogone DirectLink + AliasManager + Direct Link 3D
    # (25 April 2012).
    #
    # For any questions or comments, please contact one of the following:
    # - Joel Cogen (joel.cogen@belighted.com)
    # - Nicolas Jacobeus (nicolas.jacobeus@belighted.com),
    # - Sébastien Grosjean (public@zencocoon.com),
    # - Rémy Coutable (remy@jilion.com).
    #
    # == Usage
    #
    #   gateway = ActiveMerchant::Billing::OgoneGateway.new(
    #     :login               => "my_ogone_psp_id",
    #     :user                => "my_ogone_user_id",
    #     :password            => "my_ogone_pswd",
    #     :signature           => "my_ogone_sha_signature", # Only if you configured your Ogone environment so.
    #     :signature_encryptor => "sha512"                  # Can be "none" (default), "sha1", "sha256" or "sha512".
    #                                                       # Must be the same as the one configured in your Ogone account.
    #   )
    #
    #   # set up credit card object as in main ActiveMerchant example
    #   creditcard = ActiveMerchant::Billing::CreditCard.new(
    #     :type       => 'visa',
    #     :number     => '4242424242424242',
    #     :month      => 8,
    #     :year       => 2009,
    #     :first_name => 'Bob',
    #     :last_name  => 'Bobsen'
    #   )
    #
    #   # run request
    #   response = gateway.purchase(1000, creditcard, :order_id => "1") # charge 10 EUR
    #
    #   If you don't provide an :order_id, the gateway will generate a random one for you.
    #
    #   puts response.success?      # Check whether the transaction was successful
    #   puts response.message       # Retrieve the message returned by Ogone
    #   puts response.authorization # Retrieve the unique transaction ID returned by Ogone
    #   puts response.order_id      # Retrieve the order ID
    #
    # == Alias feature
    #
    #   To use the alias feature, simply add :billing_id in the options hash:
    #
    #   # Associate the alias to that credit card
    #   gateway.purchase(1000, creditcard, :order_id => "1", :billing_id => "myawesomecustomer")
    #
    #   # You can use the alias instead of the credit card for subsequent orders
    #   gateway.purchase(2000, "myawesomecustomer", :order_id => "2")
    #
    #   # You can also create an alias without making a purchase using store
    #   gateway.store(creditcard, :billing_id => "myawesomecustomer")
    #
    #   # When using store, you can also let Ogone generate the alias for you
    #   response = gateway.store(creditcard)
    #   puts response.billing_id # Retrieve the generated alias
    #
    #   # By default, Ogone tries to authorize 0.01 EUR but you can change this
    #   # amount using the :store_amount option when creating the gateway object:
    #   gateway = ActiveMerchant::Billing::OgoneGateway.new(
    #     :login               => "my_ogone_psp_id",
    #     :user                => "my_ogone_user_id",
    #     :password            => "my_ogone_pswd",
    #     :signature           => "my_ogone_sha_signature",
    #     :signature_encryptor => "sha512",
    #     :store_amount        => 100 # The store method will try to authorize 1 EUR instead of 0.01 EUR
    #   )
    #   response = gateway.store(creditcard) # authorize 1 EUR and void the authorization right away
    #
    # == 3-D Secure feature
    #
    #   To use the 3-D Secure feature, simply add :d3d => true in the options hash:
    #   gateway.purchase(2000, "myawesomecustomer", :order_id => "2", :d3d => true)
    #
    #   Specific 3-D Secure request options are (please refer to the documentation for more infos about these options):
    #     :win_3ds         => :main_window (default), :pop_up or :pop_ix.
    #     :http_accept     => "*/*" (default), or any other HTTP_ACCEPT header value.
    #     :http_user_agent => The cardholder's User-Agent string
    #     :accept_url      => URL of the web page to show the customer when the payment is authorized.
    #                         (or waiting to be authorized).
    #     :decline_url     => URL of the web page to show the customer when the acquirer rejects the authorization
    #                         more than the maximum permitted number of authorization attempts (10 by default, but can
    #                         be changed in the "Global transaction parameters" tab, "Payment retry" section of the
    #                         Technical Information page).
    #     :exception_url   => URL of the web page to show the customer when the payment result is uncertain.
    #     :paramplus       => Field to submit the miscellaneous parameters and their values that you wish to be
    #                         returned in the post sale request or final redirection.
    #     :complus         => Field to submit a value you wish to be returned in the post sale request or output.
    #     :language        => Customer's language, for example: "en_EN"
    #
    class OgoneGateway < Gateway
      CVV_MAPPING = { 'OK' => 'M',
                      'KO' => 'N',
                      'NO' => 'P' }

      AVS_MAPPING = { 'OK' => 'M',
                      'KO' => 'N',
                      'NO' => 'R' }

      SUCCESS_MESSAGE = "The transaction was successful"

      THREE_D_SECURE_DISPLAY_WAYS = { :main_window => 'MAINW',  # display the identification page in the main window
                                                                # (default value).
                                      :pop_up      => 'POPUP',  # display the identification page in a pop-up window
                                                                # and return to the main window at the end.
                                      :pop_ix      => 'POPIX' } # display the identification page in a pop-up window
                                                                # and remain in the pop-up window.

      OGONE_NO_SIGNATURE_DEPRECATION_MESSAGE   = "Signature usage will be the default for a future release of ActiveMerchant. You should either begin using it, or update your configuration to explicitly disable it (signature_encryptor: none)"
      OGONE_STORE_OPTION_DEPRECATION_MESSAGE   = "The 'store' option has been renamed to 'billing_id', and its usage is deprecated."

      self.test_url = "https://secure.ogone.com/ncol/test/"
      self.live_url = "https://secure.ogone.com/ncol/prod/"

      self.supported_countries = ['BE', 'DE', 'FR', 'NL', 'AT', 'CH']
      # also supports Airplus and UATP
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :discover, :jcb, :maestro]
      self.homepage_url = 'http://www.ogone.com/'
      self.display_name = 'Ogone'
      self.default_currency = 'EUR'
      self.money_format = :cents
      self.ssl_version = :TLSv1

      def initialize(options = {})
        requires!(options, :login, :user, :password)
        super
      end

      def direct_entry_debit amount, iban, account_name, options = {}
        requires! options, :order_id, :address, :postcode, :city

        post = {}
        add_pair post, "PM", "Direct Debits DE"
        add_pair post, 'CARDNO', iban

        add_pair post, "CN", account_name
        add_pair post, "OWNERADDRESS", options[:address]
        add_pair post, "OWNERZIP", options[:postcode]
        add_pair post, "OWNERTOWN", options[:city]
        add_pair post, "ORDERID", options[:order_id]
        add_pair post, "ED", "9999"
        add_pair post, 'AMOUNT', amount
        add_pair post, 'CURRENCY', 'EUR'

        commit('SAL', post)
      end

      private
      def parse(body)
        xml_root = REXML::Document.new(body).root
        response = convert_attributes_to_hash(xml_root.attributes)

        # Add HTML_ANSWER element (3-D Secure specific to the response's params)
        # Note: HTML_ANSWER is not an attribute so we add it "by hand" to the response
        if html_answer = REXML::XPath.first(xml_root, "//HTML_ANSWER")
          response["HTML_ANSWER"] = html_answer.text
        end

        response
      end

      def commit(action, parameters)
        add_pair parameters, 'PSPID',  @options[:login]
        add_pair parameters, 'USERID', @options[:user]
        add_pair parameters, 'PSWD',   @options[:password]

        response = parse(ssl_post(url(parameters['PAYID']), post_data(action, parameters)))

        options = {
          :authorization => [response["PAYID"], action].join(";"),
          :test          => test?,
          :avs_result    => { :code => AVS_MAPPING[response["AAVCheck"]] },
          :cvv_result    => CVV_MAPPING[response["CVCCheck"]]
        }
        OgoneResponse.new(successful?(response), message_from(response), response, options)
      end

      def url(payid)
        (test? ? test_url : live_url) + (payid ? "maintenancedirect.asp" : "orderdirect.asp")
      end

      def successful?(response)
        response["NCERROR"] == "0"
      end

      def message_from(response)
        if successful?(response)
          SUCCESS_MESSAGE
        else
          format_error_message(response["NCERRORPLUS"])
        end
      end

      def format_error_message(message)
        raw_message = message.to_s.strip
        case raw_message
        when /\|/
          raw_message.split("|").join(", ").capitalize
        when /\//
          raw_message.split("/").first.to_s.capitalize
        else
          raw_message.to_s.capitalize
        end
      end

      def post_data(action, parameters = {})
        add_pair parameters, 'Operation', action
        add_signature(parameters)
        parameters.to_query
      end

      def add_signature(parameters)
        if @options[:signature].blank?
           ActiveMerchant.deprecated(OGONE_NO_SIGNATURE_DEPRECATION_MESSAGE) unless(@options[:signature_encryptor] == "none")
           return
        end

        sha_encryptor = case @options[:signature_encryptor]
                        when 'sha256'
                          Digest::SHA256
                        when 'sha512'
                          Digest::SHA512
                        else
                          Digest::SHA1
                        end

        string_to_digest = if @options[:signature_encryptor]
          parameters.sort { |a, b| a[0].upcase <=> b[0].upcase }.map { |k, v| "#{k.upcase}=#{v}" }.join(@options[:signature])
        else
          %w[orderID amount currency CARDNO PSPID Operation ALIAS].map { |key| parameters[key] }.join
        end
        string_to_digest << @options[:signature]

        add_pair parameters, 'SHASign', sha_encryptor.hexdigest(string_to_digest).upcase
      end

      def add_pair(post, key, value)
        post[key] = value if !value.blank?
      end

      def convert_attributes_to_hash(rexml_attributes)
        response_hash = {}
        rexml_attributes.each do |key, value|
          response_hash[key] = value
        end
        response_hash
      end
    end

    class OgoneResponse < Response
      def order_id
        @params['orderID']
      end

      def billing_id
        @params['ALIAS']
      end
    end
  end
end
