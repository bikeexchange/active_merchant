module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PayOneGateway < Gateway
      URL = 'https://api.pay1.de/post-gateway/'

      # The countries the gateway supports merchants from as 2 digit ISO country codes
      self.supported_countries = ['DE', 'NL', 'BE']

      # The card types supported by the payment gateway
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :jcb]

      # The homepage URL of the gateway
      self.homepage_url = 'http://payone.de/'

      # The name of the gateway
      self.display_name = 'PayOne'

      self.money_format = :cents

      def initialize options = {}
        requires!(options, :mid, :portalid, :aid, :key)
        @options = options.reject{|_,v| v.blank?}
        super
      end

      def test?
        @options[:mode] == 'test' || super
      end

      def purchase( money, creditcard_or_userid, options = {} )
        post = {}
        add_creditcard_or_userid(post, creditcard_or_userid, options)
        add_address(post, options)
        add_personal_data(post, options)
        add_invoice_details(post, options)
        add_reference(post, options)

        commit('authorization', money, post)
      end

      def authorize money, userid, options = {}
        post = {}
        add_reference(post, options)
        add_creditcard_or_userid(post, creditcard_or_userid, options)
        add_address(post, options)
        add_personal_data(post, options)
        add_invoice_details(post, options)

        commit('preauthorization', money, post)
      end

      def capture( money, authorization, options = {} )
        post = {}
        post[:id] = options[:id]
        post[:pr] = options[:pr]
        post[:no] = options[:no]
        post[:de] = options[:de]
        post[:txid] = authorization
        add_reference(post, options)
        commit('capture', money, post)
      end

      # can do a 'debit' of one of the sub-accounts instead of a refund
      def refund amount, transaction_id, options = {}
        post = {}
        post[:txid] = transaction_id
        post[:amount] = amount
        post[:currency] = 'EUR'
        post[:sequencenumber] = options[:sequencenumber]
        # authorization (0)
        # refund (1)
        # OR
        # preauthorization (0)
        # capture (1)
        # refund (2)

        # optional
        post[:narrative_text] = options[:narrative_text]
        post[:use_customerdata] = options[:use_customerdata]

        commit('refund', amount, post)
      end

      def update_user customer_id: nil, user_id: nil, options: {}
        return unless customer_id.presence || user_id.presence
        permitted_params
      end

      private

      def customer_params
        (%w{
            salutation
            title
            addressaddition
            email
            telephonenumber
            birthday
            language
            vatid
            accessname
            accesscode
            delete_carddata        # yes | no
            delete_bankaccountdata # yes | no
          } + basic_customer_params).map(&:to_sym)
      end

      def basic_customer_params
        %w{
          firstname
          lastname
          company
          street
          zip
          city
          state
          country
        }
      end

      def shipping_params
        basic_customer_params.map{|x| "shipping_#{x}".to_sym}
      end

      def bank_account_params
        %i{
          bankcountry         # Account type/country, for use with BBAN mandatory with bankcode, bankaccount optional with iban/bic
          bankaccountbankcode # not in NL
          bankbranchcode      # only for only for FR, ES, FI, IT
          bankcheckdigit      # only for FR, BE
          bankaccountholder
          iban                # If both (BBAN and IBAN) are submitted, IBAN is splitted into BBAN and processed
          bic
        }
      end

      # cardtype:
      #
      # V: Visa
      # M: MasterCard
      # A: Amex
      # D: Diners
      # J: JCB
      # O: Maestro International U: Maestro UK
      # C: Discover
      # B: Carte Bleue
      def credit_card_params
        %i{
          cardholder
          cardpan
          cardtype
          cardexpiredate
          cardissuenumber
          pseudocardpan
        }
      end

      def add_invoice_details( post, options )
        if options[:invoice_details]
          post['id[1]'.to_sym] = options[:invoice_details][:id]
          post['pr[1]'.to_sym] = options[:invoice_details][:pr]
          post['no[1]'.to_sym] = options[:invoice_details][:no]
          post['de[1]'.to_sym] = options[:invoice_details][:de]
          post['va[1]'.to_sym] = options[:invoice_details][:va]
        end
      end

      def add_reference( post, options )
        post[:reference] = options[:reference]
      end

      def add_personal_data post, options
        %w(customerid salutation firstname lastname company email).each do |key|
          if options[key.to_sym] && !post[key.to_sym]
            post[key.to_sym] = options[key.to_sym]
          end
        end
      end

      def add_address( post, options )
        if options[:address]
          post[:street]   = options[:address][:street]
          post[:zip]      = options[:address][:zip]
          post[:city]     = options[:address][:city]
          post[:country]  = options[:address][:country]
        end
      end

      def add_invoice( post, options )
        post[:clearingtype] = 'rec'
        post[:vatid] = options[:vatid]
      end

      def add_creditcard_or_userid( post, creditcard_or_userid, options = {} )
        if creditcard_or_userid.instance_of?(CreditCard)
          add_creditcard(post, creditcard_or_userid)
        elsif creditcard_or_userid.instance_of?(Fixnum)
          add_userid(post, creditcard_or_userid)
        elsif creditcard_or_userid.instance_of?(String)
          add_invoice(post, options)
        end
      end

      def add_creditcard( post, creditcard )
        post[:cardpan] = creditcard.number
        post[:cardexpiredate] = expdate(creditcard)
        post[:cardcvc2] = creditcard.verification_value if creditcard.verification_value
        post[:clearingtype] = "cc"
        post[:cardholder] = ??
        post[:ecommercemode] = 'internet' || '3dsecure'

        post[:firstname] = creditcard.first_name
        post[:lastname] = creditcard.last_name

        post[:cardtype] = case creditcard.brand
                            when 'visa' then 'V'
                            when 'master' then 'M'
                            when 'diners_club' then 'D'
                            when 'american_express' then 'A'
                            when 'jcb' then 'J'
                            when 'maestro' then 'O'
                            # U Maestro UK
                            # C Discover
                            # B Carte Bleue
                          end
        post[:cardissuenumber] # only Maestro UK
      end

      def add_3dsecure post, options
        permitted_params = [:xid, :cavv, :eci, :successurl, :errorurl]
        post.merge!(options.slice(*permitted_params))
        post[:clearingtype]
      end

      def add_userid( post, userid )
        post[:userid] = userid
        post[:clearingtype] = "cc"
      end

      def add_debit post, options
        permitted_params = [:bankcountry, :bankaccount, :bankcode, :bankaccountholder, :iban, :bic]
        post.merge!(options.slice(*permitted_params))
        post[:clearingtype] = 'elv'
      end

      def add_online_transfer post, options
        permitted_params = [:onlinebanktransfertype, :bankcountry, :bankaccount, :bankcode, :bankgrouptype, :iban, :bic, :successurl, :errorurl, :backurl]
        post.merge!(options.slice(*permitted_params))
        post[:clearingtype] = 'sb'
      end

      def add_ewallet
        # wallettype: 'PPE' for PayPal Express
        permitted_params = [:wallettype, :successurl, :errorurl, :backurl]
        post.merge!(options.slice(*permitted_params))
        post[:clearingtype] = 'wlt'
      end

      def parse( body )
        results = {}

        body.split(/\n/).each do |pair|
          key,val = pair.split(/=/)
          results[key] = val
        end

        results
      end

      def commit( action, money, post )
        require 'digest/md5'

        post[:mid]        = @options[:mid]
        post[:portalid]   = @options[:portalid]
        post[:aid]        = @options[:aid]
        post[:key]        = Digest::MD5.hexdigest(@options[:key])
        post[:mode]       = test? ? 'test' : 'live'
        post[:amount]     = money
        post[:request]    = action
        post[:currency]   = "EUR"
        post[:country]    = "DE"

        clean_and_stringify_post(post)

        response = parse( ssl_post(URL, post_data(post)) )

        success = response["status"] == "APPROVED"

        #puts post_data(post) unless success

        message = message_from(response)

        Response.new(success, message, { :response => response, :userid => response["userid"] },
                     { :test => test?, :authorization => response["txid"] }
        )
      end

      def message_from( response )
        status = case response["status"]
                   when "ERROR"
                     #puts response["errorcode"]
                     #puts response["customermessage"]
                     #puts response["errormessage"]
                     response["errormessage"]
                   else
                     return "The transaction was successful"
                 end
      end

      def post_data( post = {} )
        post.collect { |key, value| "#{key}=#{ CGI.escape(value.to_s)}" }.join("&")
      end

      def clean_and_stringify_post( post )
        post.keys.reverse.each do |key|
          if post[key]
            post[key.to_s] = post[key]
          end
          post.delete(key)
        end
      end

      def expdate( creditcard )
        year  = sprintf("%.4i", creditcard.year)
        month = sprintf("%.2i", creditcard.month)

        "#{year[-2..-1]}#{month}"
      end
    end
  end
end
