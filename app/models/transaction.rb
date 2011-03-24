# encoding: utf-8
# author: Boris Barroso
# email: boriscyber@gmail.com
class Transaction < ActiveRecord::Base
  acts_as_org

  STATES   = ["draft"  , "approved" , "paid" , "due"]
  TYPES    = ['Income' , 'Expense'  , 'Buy']
  DECIMALS = 2
  # Determines if the oprations is made on transaction or pay_plan or payment
  attr_reader :trans
  # callbacks
  after_initialize :set_defaults, :if => :new_record?
  after_initialize :set_trans_to_true

  before_save      :set_details_type
  before_save      :calculate_total_and_set_balance, :if => :trans?
  before_save      :update_payment_date
  before_save      :set_state

  after_update     :update_transaction_pay_plans, :if => :trans?

  # relationships
  belongs_to :contact
  belongs_to :currency
  belongs_to :project

  has_many :pay_plans          , :dependent => :destroy , :order => "payment_date ASC"
  has_many :payments           , :dependent => :destroy
  has_many :transaction_details, :dependent => :destroy

  has_and_belongs_to_many :taxes, :class_name => 'Tax'
  # nested attributes
  accepts_nested_attributes_for :transaction_details, :allow_destroy => true

  # scopes
  scope :draft    , where(:state => 'draft')
  scope :approved , where(:state => 'approved')
  scope :paid     , where(:state => 'paid')
  scope :due      , where(["transactions.state = ? AND transactions.payment_date < ?" , 'approved' , Date.today])
  scope :credit   , where(:cash => false)

  delegate :name, :symbol, :plural, :code, :to => :currency, :prefix => true

  ###############################
  # Methods for pay_plans
  include ::Transaction::PayPlans
  ###############################

  # Define boolean methods for states
  STATES.each do |state|
    class_eval <<-CODE, __FILE__, __LINE__ + 1
      def #{state}?
        "#{state}" == state ? true : false
      end
    CODE
  end

  def self.all_states
    STATES + ["awaiting_payment"]
  end

  # Finds using the state
  def self.find_with_state(state)
    state = 'all' unless all_states.include?(state)
    ret   = Income.org.includes(:contact, :pay_plans, :currency).order("date DESC")

    case state
    when 'all' then ret
    when 'awaiting_payment' then ret.approved.credit
    else ret.send(state)
    end
  end

  # Define methods for the types of transactions
  TYPES.each do |type|
    class_eval <<-CODE, __FILE__, __LINE__ + 1
      def #{type.downcase}?
        "#{type}" == type
      end
    CODE
  end

  def to_json
    attributes.merge(:currency_symbol => currency_symbol, :real_state => real_state).to_json
  end

  # downcased type
  def typed
    type.downcase
  end

  # Transalates the type for any language
  def type_translated
    arr = case I18n.locale
      when :es
        ['Venta', 'Gasto', 'Compra']
    end
    Hash[TYPES.zip(arr)][type]
  end

  # Presents a localized name for state
  def show_state
    @hash ||= create_states_hash
    @hash[real_state]
  end

  # Returns the real state based on state and checked payment_date
  def real_state
    if state == "approved" and !payment_date.blank? and payment_date < Date.today
      "due"
    else
      state
    end
  end

  def show_pay_plans?
    if state == "draft"
      true
    elsif state != "draft" and !cash
      true
    end
  end

  def show_payments?
    state != 'draft'
  end

  # quantity without discount and taxes
  def subtotal
    self.transaction_details.inject(0) {|sum, v| sum += v.total }
  end

  # Calculates the amount for taxes
  def total_taxes
    (gross_total - total_discount ) * tax_percent/100
  end

  def total_discount
    gross_total * discount/100
  end

  def total_payments
    payments.inject(0) {|sum, v| sum += v.amount }
  end

  def total_payments_with_interests
    payments.inject(0) {|sum, v| sum += v.amount + v.interests_penalties }
  end

  # Presents the currency symbol name if not default currency
  def present_currency
    unless Organisation.find(OrganisationSession.organisation_id).id == self.currency_id
      self.currency.to_s
    end
  end

  # Presents the total in currency unless the default currency
  def total_currency
    (self.total/self.currency_exchange_rate).round(DECIMALS)
  end

  # Sums the total of payments
  def payments_total
    payments.sum(:amount)
  end

  # Sums the total amount of the payments and interests
  def payments_amount_interests_total
    payments.sum(:amount) + payments.sum(:interests_penalties)
  end

  # Returns the total value of pay plans that haven't been paid'
  def pay_plans_total
    pay_plans.unpaid.sum('amount')
  end

  # Returns the total amount to be paid for unpaid pay_plans
  def pay_plans_balance
    balance - pay_plans_total
  end

  # Updates cash based on the pay_plans
  def update_pay_plans_cash
    self.cash = ( pay_plans.size > 0 )
    self.save
  end

  # Sets a default payment date using PayPlan
  def update_payment_date
    # Do not user PayPlan.unpaid.where(:transaction_id => id).limit(1) 
    # because it can't find a created pay_pland in the middle of a transaction
    pp = pay_plans.unpaid.where(:transaction_id => id).limit(1)

    if pp.any?
      self.payment_date = pp.first.payment_date
    else
      self.payment_date = self.date
    end
  end

  # Prepares a payment with the current notes to pay
  # @param Hash options
  def new_payment(options = {})
    amt = int_pen = 0
    if pay_plans.unpaid.any?
      pp = pay_plans.unpaid.first
      amt, int_pen =  [pp.amount, pp.interests_penalties]
    else
      amt = balance
    end

    options[:amount] = options[:amount] || amt
    options[:interests_penalties] = options[:interests_penalties] || int_pen
    payments.build({:transaction_id => id, :currency_id => currency_id}.merge(options))
  end


  # Adds a payment and updates the balance
  def add_payment(amount)
    if amount > balance
      return false
    else
      @trans = false
      self.balance = (balance - amount)
      self.save
    end
  end

  # Substract the amount from the balance
  def substract_payment(amount)
    @trans = false
    self.balance = (balance + amount)
    self.save
  end

  def real_total
    total / currency_exchange_rate
  end

  def set_trans(value)
    @trans = value
  end

  # Returs the pay_type for the current instance
  def pay_type
    case type
    when "Income" then "cobro"
    when "Buy", "Expense" then "pago"
    end
  end

private

  def set_state
    if balance.to_f <= 0
      self.state = "paid"
    elsif state == 'paid' and balance > 0
      self.state = 'approved'
    elsif state.blank?
      self.state = "draft"
    end
  end

  # set default values for discount and taxes
  def set_defaults
    self.cash = cash.nil? ? true : cash
    self.active = active.nil? ? true : active
    self.discount ||= 0
    self.tax_percent = taxes.inject(0) {|sum, t| sum += t.rate }
    self.gross_total ||= 0
    self.total ||= 0
  end

  def set_trans_to_true
    @trans = true
  end


  # Sets the type of the class making the transaction
  def set_details_type
    self.transaction_details.each{ |v| v.ctype = self.class.to_s }
  end

  # Calculates the total value and stores it
  def calculate_total_and_set_balance
    self.gross_total = transaction_details.select{|t| !t.marked_for_destruction? }.inject(0) {|sum, det| sum += det.total }
    self.total = gross_total - total_discount + total_taxes
    self.balance = total / currency_exchange_rate
  end

  # Determines if it is a transaction or other operation
  def trans?
    @trans
  end
end
