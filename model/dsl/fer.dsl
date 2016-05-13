module fer
{
  aggregate Predavanje {
    String  naziv;
    String  predavac;

    calculated Boolean jelImaVezeSaPostgresom from 'it => it.naziv.Contains("PostgreSQL")';
  }
}
