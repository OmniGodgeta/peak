use crate::{Client, Processed};

const GID: &[u8] = b"conversation-1";

fn pair() -> (Client, Client) {
    let alice = Client::new(b"alice:phone").unwrap();
    let bob = Client::new(b"bob:phone").unwrap();
    alice.create_group(GID).unwrap();
    let kp = bob.key_package().unwrap();
    let (_commit, welcome) = alice.add_members(GID, &[kp]).unwrap();
    assert_eq!(bob.join(&welcome).unwrap(), GID);
    (alice, bob)
}

#[test]
fn two_devices_talk_both_ways() {
    let (alice, bob) = pair();
    let m = alice.encrypt(GID, b"hi bob").unwrap();
    assert_eq!(
        bob.process(GID, &m).unwrap(),
        Processed::Application(b"hi bob".to_vec())
    );
    let r = bob.encrypt(GID, b"hi alice").unwrap();
    assert_eq!(
        alice.process(GID, &r).unwrap(),
        Processed::Application(b"hi alice".to_vec())
    );
    assert_eq!(alice.epoch(GID).unwrap(), bob.epoch(GID).unwrap());
}

#[test]
fn ciphertext_is_not_plaintext() {
    let (alice, _bob) = pair();
    let m = alice.encrypt(GID, b"secret words here").unwrap();
    assert!(!m.windows(12).any(|w| w == b"secret words"));
}

#[test]
fn state_survives_save_and_load() {
    let (alice, bob) = pair();
    let alice = Client::load(&alice.save().unwrap()).unwrap();
    let bob = Client::load(&bob.save().unwrap()).unwrap();
    let m = alice.encrypt(GID, b"after restart").unwrap();
    assert_eq!(
        bob.process(GID, &m).unwrap(),
        Processed::Application(b"after restart".to_vec())
    );
    assert_eq!(alice.identity(), b"alice:phone");
}

#[test]
fn a_third_device_joins_and_everyone_follows_the_commit() {
    let (alice, bob) = pair();
    let carol = Client::new(b"carol:tablet").unwrap();
    let (commit, welcome) = alice
        .add_members(GID, &[carol.key_package().unwrap()])
        .unwrap();
    assert_eq!(
        bob.process(GID, &commit).unwrap(),
        Processed::Commit(alice.epoch(GID).unwrap())
    );
    carol.join(&welcome).unwrap();
    let m = carol.encrypt(GID, b"hello both").unwrap();
    assert_eq!(
        alice.process(GID, &m).unwrap(),
        Processed::Application(b"hello both".to_vec())
    );
    assert_eq!(
        bob.process(GID, &m).unwrap(),
        Processed::Application(b"hello both".to_vec())
    );
    let mut ids = alice.members(GID).unwrap();
    ids.sort();
    assert_eq!(
        ids,
        vec![
            b"alice:phone".to_vec(),
            b"bob:phone".to_vec(),
            b"carol:tablet".to_vec()
        ]
    );
}

#[test]
fn a_removed_device_cannot_read_new_messages() {
    let (alice, bob) = pair();
    let carol = Client::new(b"carol:tablet").unwrap();
    let (c1, w) = alice
        .add_members(GID, &[carol.key_package().unwrap()])
        .unwrap();
    bob.process(GID, &c1).unwrap();
    carol.join(&w).unwrap();
    let c2 = alice
        .remove_members(GID, &[b"carol:tablet".to_vec()])
        .unwrap();
    bob.process(GID, &c2).unwrap();
    let m = alice.encrypt(GID, b"carol is gone").unwrap();
    assert!(carol.process(GID, &m).is_err());
    assert_eq!(
        bob.process(GID, &m).unwrap(),
        Processed::Application(b"carol is gone".to_vec())
    );
}

#[test]
fn outsiders_and_garbage_are_errors_not_panics() {
    let (alice, _bob) = pair();
    let eve = Client::new(b"eve:laptop").unwrap();
    let m = alice.encrypt(GID, b"x").unwrap();
    assert!(eve.process(GID, &m).is_err());
    assert!(alice.process(GID, b"\x00\x01garbage").is_err());
    assert!(Client::load(b"not a state").is_err());
    assert!(alice.join(b"nope").is_err());
    assert!(alice.encrypt(b"no-such-group", b"x").is_err());
}

#[test]
fn a_key_package_is_single_use() {
    let alice = Client::new(b"alice:phone").unwrap();
    let bob = Client::new(b"bob:phone").unwrap();
    let kp = bob.key_package().unwrap();
    alice.create_group(b"g1").unwrap();
    alice.create_group(b"g2").unwrap();
    let (_, w1) = alice.add_members(b"g1", std::slice::from_ref(&kp)).unwrap();
    let (_, w2) = alice.add_members(b"g2", &[kp]).unwrap();
    bob.join(&w1).unwrap();
    // The private key behind that package was consumed by the first join.
    assert!(bob.join(&w2).is_err());
}
