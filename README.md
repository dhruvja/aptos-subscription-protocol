# aptos-subscription-protocol
A protocol which allows you to perform subscription payments

This protocol would allow you to perform subscription to the platform through delegation. The merchants can set up the payment configuration with all the details
and the subscribers can add their information and transfer the amount if required by the merchant on init.

Then the subscriber can delegate their account to a resource account which would gain the signer capability over the subscriber which would collect the payments
in regular intervals. The signer capability offered to the resource account would be revoked if the delegated amount set comes to 0. The subscriber would then
have to offer the capability again.

The features of the protocol are as follows
- Can able to collect payments in regular interval of time
- Subscriber can grant the program to delegate some part of the account towards the merchant
- Subscriber can revoke the signer capability anytime.
- Merchant can change the authority with the current authority's signature.
