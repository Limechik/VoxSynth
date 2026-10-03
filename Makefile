voxtest: FormantCore.c Phonemes.c Stress.c test_main.c FormantCore.h Phonemes.h Stress.h
	cc -O2 -std=gnu99 -o voxtest FormantCore.c Phonemes.c Stress.c test_main.c -lm
clean:
	rm -f voxtest
