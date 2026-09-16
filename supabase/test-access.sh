PSQL="psql -h /tmp/pgsock -p 5433 -U postgres -d postgres -tAq"
ALICE=11111111-1111-1111-1111-111111111111
BOB=22222222-2222-2222-2222-222222222222
EVE=33333333-3333-3333-3333-333333333333
CAROL=44444444-4444-4444-4444-444444444444

# як користувач: роль authenticated + auth.uid()
asuser(){ $PSQL -c "begin; set local role authenticated; set local test.uid='$1'; $2; commit;" 2>&1 | tr -d '\r'; }

fails=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 — очікували [$3], отримали [$2]"; fails=$((fails+1)); fi; }
okfail(){ case "$2" in *ERROR*) echo "  PASS  $1 (відхилено)";; *) echo "  FAIL  $1 — запит пройшов, а мав впасти: $2"; fails=$((fails+1));; esac; }

$PSQL -c "truncate households cascade; delete from auth.users;" >/dev/null
$PSQL -c "insert into auth.users(id,email) values ('$ALICE','a@t'),('$BOB','b@t'),('$EVE','e@t'),('$CAROL','c@t');" >/dev/null

echo "── Аліса створює сім'ю ──"
asuser $ALICE "select 1 from create_household('Family A','Alice')" >/dev/null
H1=$($PSQL -c "select id from households limit 1")
CODE=$($PSQL -c "select join_code from households limit 1")
echo "  домогосподарство: $H1   код: $CODE"

asuser $ALICE "insert into transactions(household_id,date,kind,amount,currency,rate,eur,category,author) values ('$H1','2026-09-01','expense',100,'EUR',1,100,'Groceries','Alice')" >/dev/null
ok "Аліса бачить свою операцію" "$(asuser $ALICE 'select count(*) from transactions')" "1"

ok "Стартові групи створені"           "$(asuser $ALICE 'select count(*) from groups')" "11"
ok "У кожної групи є стаття"            "$(asuser $ALICE 'select count(*) from categories')" "11"

echo "── Боб приєднується за кодом ──"
asuser $BOB "select 1 from join_household('$CODE','Bob')" >/dev/null
ok "Боб бачить операцію Аліси" "$(asuser $BOB 'select count(*) from transactions')" "1"
asuser $BOB "insert into transactions(household_id,date,kind,amount,currency,rate,eur,category,author) values ('$H1','2026-09-02','income',500,'EUR',1,500,'Salary','Bob')" >/dev/null
ok "Боб може вносити, Аліса це бачить" "$(asuser $ALICE 'select count(*) from transactions')" "2"

echo "── Стороння людина ──"
ok "Єва НЕ бачить чужих операцій"      "$(asuser $EVE 'select count(*) from transactions')" "0"
ok "Єва НЕ бачить чужих домогосподарств" "$(asuser $EVE 'select count(*) from households')" "0"
ok "Єва НЕ бачить чужих налаштувань"   "$(asuser $EVE 'select count(*) from settings')" "0"
ok "Єва НЕ бачить чужих кредитів"      "$(asuser $EVE 'select count(*) from loans')" "0"
ok "Єва НЕ бачить складу чужої сім'ї"  "$(asuser $EVE 'select count(*) from household_members')" "0"
ok "Єва НЕ бачить чужих груп"           "$(asuser $EVE 'select count(*) from groups')" "0"
ok "Єва НЕ бачить чужих статей"         "$(asuser $EVE 'select count(*) from categories')" "0"
ok "Єва НЕ бачить чужих планів"         "$(asuser $EVE 'select count(*) from plan_overrides')" "0"
asuser $ALICE "insert into tasks(household_id,due_date,due_time,title) values ('$H1','2026-09-20','10:00','Сплатити оренду')" >/dev/null
ok "Боб бачить завдання Аліси"          "$(asuser $BOB 'select count(*) from tasks')" "1"
ok "Єва НЕ бачить чужих завдань"        "$(asuser $EVE 'select count(*) from tasks')" "0"
okfail "Єва не може створити завдання в чужій сім'ї" \
  "$(asuser $EVE "insert into tasks(household_id,due_date,title) values ('$H1','2026-09-21','Hack')")"
asuser $EVE "update tasks set done=true where household_id='$H1'" >/dev/null
ok "Завдання Аліси не позначене чужим"  "$(asuser $ALICE 'select count(*) from tasks where done')" "0"

okfail "Єва не може вписати операцію в чужу сім'ю" \
  "$(asuser $EVE "insert into transactions(household_id,date,kind,amount,currency,rate,eur,category,author) values ('$H1','2026-09-03','expense',9999,'EUR',1,9999,'Hack','Eve')")"
asuser $EVE "update transactions set eur=0 where household_id='$H1'" >/dev/null
asuser $EVE "delete from transactions where household_id='$H1'" >/dev/null
ok "Після спроб Єви кількість операцій ціла" "$(asuser $ALICE 'select count(*) from transactions')" "2"
ok "Після спроб Єви суми не зіпсовані"       "$(asuser $ALICE 'select sum(eur)::int from transactions')" "600"
okfail "Неправильний код не пускає" "$(asuser $EVE "select 1 from join_household('WRONGCODE0','Eve')")"

echo "── Учасник тільки для перегляду ──"
asuser $CAROL "select 1 from join_household('$CODE','Carol',false)" >/dev/null
ok "Керол бачить операції" "$(asuser $CAROL 'select count(*) from transactions')" "2"
okfail "Керол не може міняти плани" \
  "$(asuser $CAROL "update categories set plan = 9999 where household_id='$H1'" ; asuser $CAROL "insert into categories(household_id,group_id,name) select '$H1', id, 'x' from groups limit 1")"
okfail "Керол не може вносити" \
  "$(asuser $CAROL "insert into transactions(household_id,date,kind,amount,currency,rate,eur,category,author) values ('$H1','2026-09-04','expense',50,'EUR',1,50,'Test','Carol')")"
asuser $CAROL "delete from transactions where household_id='$H1'" >/dev/null
ok "Керол не може видаляти — рядки на місці" "$(asuser $ALICE 'select count(*) from transactions')" "2"
asuser $CAROL "update transactions set eur=1 where household_id='$H1'" >/dev/null
ok "Керол не може змінювати — суми не змінились" "$(asuser $ALICE 'select sum(eur)::int from transactions')" "600"

echo "── Зміна коду запрошення ──"
NEW=$(asuser $ALICE "select rotate_join_code('$H1')")
okfail "Старий код більше не працює" "$(asuser $EVE "select 1 from join_household('$CODE','Eve')")"
echo "  новий код: $NEW"

echo
if [ $fails -eq 0 ]; then echo "УСІ ПЕРЕВІРКИ ЗАХИСТУ ПРОЙДЕНО"; else echo "$fails перевірок не пройшло"; fi
