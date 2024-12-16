import Iter "mo:base/Iter";
import Debug "mo:base/Debug";
import Random "mo:base/Random";
import Array "mo:base/Array";
import Nat "mo:base/Nat";

actor RandomExample {

  public func generateRandomArray() : async [Nat] {
    var seed = await Random.blob();
    let randomNumbers = Array.init<Nat>(10, 0);

    for (i in Iter.range(0, 9)) {
      let finiteRandom = Random.Finite(seed);
      let randNatOpt = finiteRandom.range(255); // Generate number between 0 and 255 (Nat8)
      switch (randNatOpt) {
        case (null) {
          randomNumbers[i] := 0; // Fallback in case of random failure
        };
        case (?randNat) {
          randomNumbers[i] := randNat % 50000;
          
          // TODO
          // change seed with randNat
        };
      };
    };
    return Array.freeze(randomNumbers);
  };

};
