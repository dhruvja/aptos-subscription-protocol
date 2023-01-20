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
- Subscriber can activate the subscription without losing the previous subscription data
- Merchant can change the authority with the current authority's signature.

## How to run move modules

Make sure that you have `aptos` cli installed. If not install it from here: https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli/

- Compile the module
```
aptos move compile
```
- Run the test cases
```
aptos move test
```
- Publish the module
```
aptos init
aptos move publish
```
The aptos init creates a new keypair using which the module can be published.
Note: Publishing the module with the current address wont be possible since the auth key is not present. You would have to create a new keypair and then
replace it in move.toml to continue.

## How to run tests

- Compile the module with metadata
```
aptos move compile --save-metadata
```
- Run the local node in another terminal ( since the local node runs at port `:8080` and `:8081` , make sure it is free and the `force-restart` deletes the previous logs and starts a fresh session )
```
aptos node run-local-testnet --with-faucet --force-restart --assume-yes
```
- Downloads all the packages and run the tests
```
yarn install or npm install 
```
- Run the tests
```
yarn test or npm test
```

