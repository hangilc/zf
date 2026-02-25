: fizzbuzz ( n -- )
  1 + 1 do
    i 15 mod 0= if
      ." FizzBuzz"
    else i 3 mod 0= if
      ." Fizz"
    else i 5 mod 0= if
      ." Buzz"
    else
      i .
    then then then
    ." " 
  loop cr
;

100 fizzbuzz
