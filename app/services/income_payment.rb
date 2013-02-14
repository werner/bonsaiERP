# encoding: utf-8
class IncomePayment < Payment

  # Validations
  validates_presence_of :income
  validate :valid_income_balance
  validate :valid_account_to_balance, if: :account_to_is_expense?
  validate :valid_account_to_state, if: :account_to_is_expense?

  # Delegations
  delegate :total, :balance, to: :income, prefix: true, allow_nil: true

  # Makes the payment modifiying the Income and creatinig AccountLedger
  def pay
    return false unless valid?

    commit_or_rollback do
      res = save_income
      res = save_expense if account_to_is_expense?
      res = create_ledger && res
      res = create_interest && res

      set_errors(income, ledger, int_ledger) unless res

      res
    end
  end

  def income
    @transaction = @income ||= Income.find_by_id(account_id)
  end
  alias_method :transaction, :income

private
  def save_income
    update_income

    income.save
  end

  def update_income
    income.balance -= amount_exchange
    income.set_state_by_balance! # Sets state and the user
  end

  # Updates the expense and sets it's state
  # Service exchange
  def save_expense
    account_to.balance -= amount + interest
    account_to.set_state_by_balance!

    account_to.save
  end

  def create_ledger
    if amount.to_f > 0
      @ledger = build_ledger(
                  amount: amount, operation: 'payin', account_id: income.id,
                  conciliation: conciliation?
                )
      @ledger.save_ledger
    else
      true
    end
  end

  def create_interest
    if interest.to_f > 0
      @int_ledger = build_ledger(
                      amount: interest, operation: 'intin',
                      account_id: income.id, conciliation: conciliation?
                    )
      @int_ledger.save_ledger
    else
      true
    end
  end

  def valid_income_balance
    if amount_exchange.to_f > income_balance.to_f
      self.errors.add :amount, I18n.t('errors.messages.payment.balance')
    end
  end

  def account_to_is_expense?
    account_to.is_a?(Expense)
  end

  # Only when you pay with a expense
  def valid_account_to_balance
    if  account_to.balance < (amount + interest)
      self.errors.add :amount, I18n.t('errors.messages.payment.expense_balance')
    end
  end

  def valid_account_to_state
    self.errors.add(:account_to_id, I18n.t('errors.messages.payment.invalid_expense_state')) unless account_to.is_approved?
  end

end