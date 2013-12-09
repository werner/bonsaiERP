class Loans::Query
  def all_loans
    Account.where(type: %w(Loans::Receive Loans::Give))
    .includes(:contact, :loan_extra)
  end
end
