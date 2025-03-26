stack {
  name        = "management"
  description = "management"
  id          = "17b0065c-171c-4bd0-90d9-17793673ff17"
  after = [
    "/opentofu/openbao/cluster"
  ]
}
