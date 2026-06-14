locals {
  subnet_types = {
    edge        = "10.10.1.0/24"
    application = "10.10.10.0/24"
    data        = "10.10.20.0/24"
    security    = "10.10.30.0/24"
  }

  trust_boundaries = [
    "edge-to-application-via-ingress",
    "application-to-data-only-approved-ports",
    "data-no-direct-internet-egress",
    "security-observe-all-layers"
  ]
}
