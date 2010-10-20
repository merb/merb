class Hash
  # Returns the value of self for each argument and deletes those entries.
  #
  # @param *args The keys whose values should be extracted and deleted.
  #
  # @return [Array<Object>] The values of the provided arguments in
  #   corresponding order.
  #
  # @api public
  def extract!(*args)
    args.map do |arg|
      self.delete(arg)
    end
  end
end
