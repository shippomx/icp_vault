#!/usr/bin/env bash

set -e

canister_exists() {
  (dfx canister info "$1" 2>&1 | grep 'Module hash: 0x')
}

echo
echo == Create Minting Account.
echo

if (dfx identity list | grep icrc2-vault-minter 2>&1 >/dev/null) ; then
    echo "icrc2-vault-minter account already exists" >&2
else
    dfx identity import icrc2-vault-minter --storage-mode plaintext <(cat <<EOF
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICJxApEbuZznKFpV+VKACRK30i6+7u5Z13/DOl18cIC+oAcGBSuBBAAK
oUQDQgAEPas6Iag4TUx+Uop+3NhE6s3FlayFtbwdhRVjvOar0kPTfE/N8N6btRnd
74ly5xXEBNSXiENyxhEuzOZrIWMCNQ==
-----END EC PRIVATE KEY-----
EOF
    )
fi

export MINTER=$(dfx identity get-principal --identity icrc2-vault-minter)

# The JS tests use a different principal, so we should give that some balance as well.
export JS="jg6qm-uw64t-m6ppo-oluwn-ogr5j-dc5pm-lgy2p-eh6px-hebcd-5v73i-nqe"

echo
echo == Create Canisters.
echo

dfx canister create --all

echo
echo == Deploy: Token
echo

dfx deploy token --argument "
  (variant {
    Init = record {
      token_name = \"Token A\";
      token_symbol = \"A\";
      minting_account = record {
        owner = principal \"${MINTER}\";
      };
      initial_balances = vec {
        record { record { owner = principal \"${MINTER}\"; }; 100_000_000_000_000; };
        record { record { owner = principal \"${JS}\"; }; 100_000_000_000_000; };
      };
      metadata = vec {};
      transfer_fee = 10_000;
      archive_options = record {
        trigger_threshold = 2000;
        num_blocks_to_archive = 1000;
        controller_id = principal \"${MINTER}\";
      };
      feature_flags = opt record {
        icrc2 = true;
      };
    }
  })
"

export TOKEN=$(dfx canister id token)

echo
echo == Deploy: Vault
echo

dfx deploy vault --argument "
  record {
    token = (principal \"${TOKEN}\");
  }
"

export SWAP=$(dfx canister id vault)
