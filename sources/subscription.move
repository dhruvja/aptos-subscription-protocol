module Subscription::subscription {

    use std::signer;

    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::coin;

    const EMERCHANT_AUTHORITY_ALREADY_CREATED: u64 = 0;
    const EMERCHANT_AUTHORITY_NOT_CREATED: u64 = 1;
    const EPAYMENT_CONFIG_ALREADY_CREATED: u64 = 2;
    const EPAYMENT_CONFIG_NOT_CREATED: u64 = 3;
    const ETIME_INTERVAL_NOT_ELAPSED: u64 = 4;
    const EINVALID_MERCHANT_AUTHORITY: u64 = 5;
    const ELOW_DELEGATED_AMOUNT: u64 = 6;
    const ESUBSCRIPTION_IS_INACTIVE: u64 = 7;
    const EALREADY_ACTIVE: u64 = 8;

    struct MerchantAuthority has key {
        init_authority: address,
        current_authority: address,
    } 

    struct PaymentConfig<phantom CoinType> has key {
        payment_account: address,
        merchant_authority: address,
        collect_on_init: bool,
        amount_to_collect_on_init: u64,
        amount_to_collect_per_period: u64, // in seconds
        time_interval: u64,
        subscription_name: vector<u8>,
    }

    struct PaymentMetadata<phantom CoinType> has key {
        owner: address,
        created_at: u64, // timestamp in seconds
        payment_config: address,
        amount_delegated: u64,
        payments_collected: u64,
        pending_delegated_amount: u64,
        resource_signer_cap: account::SignerCapability,
        last_payment_collection_time: u64 // timestamp in seconds
        active: bool
    }

    public entry fun initialize_merchant_authority(merchant: &signer) {
        let merchant_addr = signer::address_of(merchant);
        assert!(!exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_ALREADY_CREATED);

        move_to<MerchantAuthority>(merchant, MerchantAuthority{
            init_authority: merchant_addr,
            current_authority: merchant_addr
        });
    }

    public entry fun initialize_payment_config<CoinType>(merchant: &signer, payment_account: address, collect_on_init: bool, amount_to_collect_on_init: u64, amount_to_collect_per_period: u64, time_interval: u64, subscription_name: vector<u8>) {
        let merchant_addr = signer::address_of(merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(!exists<PaymentConfig<CoinType>>(merchant_addr), EPAYMENT_CONFIG_ALREADY_CREATED);

        let payment_config = PaymentConfig {
            payment_account,
            merchant_authority: merchant_addr,
            collect_on_init,
            amount_to_collect_on_init,
            amount_to_collect_per_period,
            time_interval,
            subscription_name
        };
        move_to<PaymentConfig<CoinType>>(merchant, payment_config);
    }

    public entry fun intialize_payment_metadata<CoinType>(subscriber: &signer, merchant_addr: address, cycles: u64, signer_capability_sig_bytes: vector<u8>, account_public_key_bytes: vector<u8>) acquires PaymentConfig {
        let subscriber_addr = signer::address_of(subscriber);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(exists<PaymentConfig<CoinType>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant_addr);

        let current_time = timestamp::now_seconds();
        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;

        // delegating the account to a resource account
        let (delegated_resource, delegated_resource_cap) = account::create_resource_account(subscriber, payment_config.subscription_name);
        let delegated_addr = signer::address_of(&delegated_resource);
        account::offer_signer_capability(subscriber, signer_capability_sig_bytes, 0, account_public_key_bytes, delegated_addr);

        if (payment_config.collect_on_init) {
            coin::transfer<CoinType>(subscriber, payment_config.payment_account, payment_config.amount_to_collect_on_init);
        };

        let payment_metadata = PaymentMetadata {
            owner: subscriber_addr,
            created_at: current_time,
            payment_config: merchant_addr,
            amount_delegated,
            payments_collected: 0,
            pending_delegated_amount: amount_delegated,
            resource_signer_cap: delegated_resource_cap,
            last_payment_collection_time: 0,
            active: true
        };
        move_to<PaymentMetadata<CoinType>>(subscriber, payment_metadata);
    }

    public entry fun collect_payment<CoinType>(merchant: &signer, customer: address) acquires PaymentConfig, PaymentMetadata {
        let merchant_addr = signer::address_of(merchant);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant_addr);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(customer);
        assert!(payment_metadata.payment_config == merchant_addr, EINVALID_MERCHANT_AUTHORITY);
        assert!(payment_metadata.active, ESUBSCRIPTION_IS_INACTIVE);

        let current_time = timestamp::now_seconds();
        assert!(current_time > (payment_metadata.last_payment_collection_time + payment_config.time_interval), ETIME_INTERVAL_NOT_ELAPSED);
        assert!(payment_metadata.pending_delegated_amount > payment_metadata.amount_to_collect_period, ELOW_DELEGATED_AMOUNT);

        // derive the resource address using the capability
        let delegated_account = account::create_signer_with_capability(&payment_metadata.resource_signer_cap);
        let delegated_signer = account::create_authorized_signer(&delegated_account, customer);

        // Transfer the amount to merchant account
        coin::transfer<CoinType>(&delegated_signer, payment_config.payment_account, payment_metadata.amount_to_collect_period);

        // Subtract the amount debited from pending delegated amount
        payment_metadata.pending_delegated_amount = payment_metadata.pending_delegated_amount - payment_metadata.amount_to_collect_per_period;
        payment_metadata.last_payment_collection_time = timestamp::now_seconds();
        payment_metadata.payments_collected = payment_metadata.payments_collected + payment_metadata.amount_to_collect_per_period;
    }

    public entry fun revoke_subscription<CoinType>(subscriber: &signer, merchant: address) acquires PaymentConfig, PaymentMetadata {
        let subscriber_addr = signer::address_of(merchant);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 

        // fetching the resource account from capability
        let delegated_address = account::get_signer_capability_address(&payment_metadata.resource_signer_cap);

        // Revoking the signer capability
        account::revoke_signer_capability(subscriber, delegated_address);

        // making the status as inactive
        payment_metadata.active = false;

        // making delegated amount is total delegated amount - pending delegated amount since the rest would be 0
        payment_metadata.amount_delegated = payment_metadata.amount_delegated - payment_metadata.pending_delegated_amount;

        // making pending delegated amount as 0
        payment_metadata.pending_delegated_amount = 0;
    }

    public entry fun activate_subscription<CoinType>(subscriber: &signer, merchant: address, cycles: u64, signer_capability_sig_bytes: vector<u8>, account_public_key_bytes: vector<u8>) acquires PaymentConfig, PaymentMetadata {
        let subscriber_addr = signer::address_of(merchant);
        let payment_config = borrow_global<PaymentConfig<CoinType>>(merchant);
        let payment_metadata = borrow_global_mut<PaymentMetadata<CoinType>>(subscriber_addr);
        assert!(payment_metadata.payment_config == merchant, EINVALID_MERCHANT_AUTHORITY); 
        assert!(!payment_metadata.active, EALREADY_ACTIVE);
        // offer signer capability to the resource account and activate subscription
        let delegated_address = account::get_signer_capability_address(&payment_metadata.resource_signer_cap); 
        account::offer_signer_capability(subscriber, signer_capability_sig_bytes, 0, account_public_key_bytes, delegated_address);
        payment_metadata.active = true;

        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;
        payment_metadata.amount_delegated = payment_metadata.amount_delegated + amount_delegated;

    }

}