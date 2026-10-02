require "rails_helper"

RSpec.describe ModuleCatalog do
  describe ".exists?" do
    it "accepts the base key and any catalogue feature key" do
      expect(described_class.exists?("base")).to be true
      expect(described_class.exists?("clients")).to be true
      expect(described_class.exists?("bogus")).to be false
    end
  end

  it "is a display list and nothing else — permissions are Permission's job" do
    # It used to hold a second copy of the permission catalogue, which
    # the permission resolver intersected every role against. "revenue" was
    # missing from that copy, so it was silently stripped from every
    # permission list the API advertised. One list now.
    expect(described_class).not_to respond_to(:permissions_for)
    expect(described_class.constants).not_to include(:ALL_PERMISSIONS, :CATALOG, :BASE_PERMISSIONS)
  end
end
