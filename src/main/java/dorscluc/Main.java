package dorscluc;

import dorscluc.fer.*;
import dorscluc.fer.repositories.*;

import org.revenj.patterns.DataContext;
import org.revenj.patterns.ServiceLocator;

import java.time.LocalDate;
import java.util.Arrays;

class Main {
    public static void main(final String[] args) throws Exception {
        final ServiceLocator locator = Boot.configure(
                "jdbc:postgresql://localhost:5432/dorscluc_db?user=dorscluc_user&password=dorscluc_pass");

        final PredavanjeRepository predavanjeRepository = locator.resolve(PredavanjeRepository.class);

        predavanjeRepository.insert(Arrays.asList(
                new Predavanje()
                        .setNaziv("Improving PostgreSQL performance")
                        .setPredavac("Nikola Henezi"),
                new Predavanje()
                        .setNaziv("Typesafe NoSQL u PostgreSQLu")
                        .setPredavac("Marko Elezovic")
        ));

        for (final Predavanje predavanje : predavanjeRepository.search()) {
            System.out.println("-------------------");
            System.out.println("Predavanje: " + predavanje.getNaziv() + " by " + predavanje.getPredavac());
            System.out.println("Uff... jel opet pozgrez? " + predavanje.getJelImaVezeSaPostgresom());
        }
    }
}
