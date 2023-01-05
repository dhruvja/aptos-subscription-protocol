module Subscription::subscription {

    use std::signer;

    use aptos_framework::timestamp;

    const EMERCHANT_AUTHORITY_ALREADY_CREATED: u64 = 0;
    const EMERCHANT_AUTHORITY_NOT_CREATED: u64 = 1;
    const EPAYMENT_CONFIG_ALREADY_CREATED: u64 = 2;
    const EPAYMENT_CONFIG_NOT_CREATED: u64 = 3;

    struct MerchantAuthority has key {
        init_authority: address,
        current_authority: address,
    } 

    struct PaymentConfig<phantom CoinStore> has key {
        payment_account: address,
        merchant_authority: address,
        collect_on_init: bool,
        amount_to_collect_on_init: u64,
        amount_to_collect_per_period: u64,
        time_interval: u64,
        subscription_name: vector<u8>,
    }

    struct PaymentMetadata<phantom CoinStore> has key {
        owner: address,
        created_at: u64,
        payment_config: address,
        amount_delegated: u64,
        payments_collected: u64,
    }

    public entry fun initialize_merchant_authority(merchant: &signer) {
        let merchant_addr = signer::address_of(merchant);
        assert!(!exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_ALREADY_CREATED);

        move_to<MerchantAuthority>(merchant, MerchantAuthority{
            init_authority: merchant_addr,
            current_authority: merchant_addr
        });
    }

    public entry fun initialize_payment_config<CoinStore>(merchant: &signer, payment_account: address, collect_on_init: bool, amount_to_collect_on_init: u64, amount_to_collect_per_period: u64, time_interval: u64, subscription_name: vector<u8>) {
        let merchant_addr = signer::address_of(merchant);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(!exists<PaymentConfig<CoinStore>>(merchant_addr), EPAYMENT_CONFIG_ALREADY_CREATED);

        let payment_config = PaymentConfig {
            payment_account,
            merchant_authority: merchant_addr,
            collect_on_init,
            amount_to_collect_on_init,
            amount_to_collect_per_period,
            time_interval,
            subscription_name
        };
        move_to<PaymentConfig<CoinStore>>(merchant, payment_config);
    }

    public entry fun intialize_payment_metadata<CoinStore>(subscriber: &signer, merchant_addr: address, cycles: u64) acquires PaymentConfig {
        let subscriber_addr = signer::address_of(subscriber);
        assert!(exists<MerchantAuthority>(merchant_addr), EMERCHANT_AUTHORITY_NOT_CREATED);
        assert!(exists<PaymentConfig<CoinStore>>(merchant_addr), EPAYMENT_CONFIG_NOT_CREATED);

        let payment_config = borrow_global<PaymentConfig<CoinStore>>(merchant_addr);

        let current_time = timestamp::now_microseconds();
        let amount_delegated = cycles * payment_config.amount_to_collect_per_period;
        let payment_metadata = PaymentMetadata {
            owner: subscriber_addr,
            created_at: current_time,
            payment_config: merchant_addr,
            amount_delegated,
            payments_collected: 0
        };
        move_to<PaymentMetadata<CoinStore>>(subscriber, payment_metadata);
    }
}