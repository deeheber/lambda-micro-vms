# lambda-micro-vms

A minimal "hello world" for [AWS Lambda MicroVMs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html).
It builds a MicroVM image with CloudFormation, runs a MicroVM, calls it over HTTPS, then suspends, resumes and terminates it.
It's meant for learning the service and as a template to fork.

> Status: the spec is in progress (`docs/SPEC.md`). The code is built from that spec by a [Kūkulu](https://github.com/displacetech/kukulu) flight.
